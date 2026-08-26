import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';

/**
 * Provisions the infrastructure for a HOOPS Visualize Web (HVW) server behind
 * an NGINX reverse proxy, following the TechSoft3D articles:
 *   - "HOOPS Visualize Web HTTPS server with reverse proxy" (topic 1682)
 *   - "How to setup HTTPS server with AWS" (topic 1680)
 *
 * What this stack creates:
 *   - A minimal VPC with a single public subnet (no NAT gateway).
 *   - A security group opening 22 (SSH), 80 (HTTP) and 443 (HTTPS). Port 11182
 *     is intentionally NOT exposed; the SC server is reached only via the
 *     NGINX /wsproxy and /httpproxy reverse-proxy routes.
 *   - An Ubuntu 24.04 LTS EC2 instance bootstrapped (via user-data) with NGINX,
 *     certbot, the reverse-proxy config, the mjs MIME type, a sample.html and a
 *     systemd boot service.
 *   - An Elastic IP associated with the instance (stable address for DNS).
 *   - An IAM role with SSM core policy so you can connect via Session Manager.
 *
 * Domain registration + certbot SSL issuance are performed manually AFTER
 * deployment (see README), because Let's Encrypt requires the DNS record to
 * already point at the Elastic IP.
 */
export class HvwCdkStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ------------------------------------------------------------------
    // Configuration (override with `cdk deploy -c key=value`)
    // ------------------------------------------------------------------
    const instanceTypeCtx = (this.node.tryGetContext('instanceType') as string) ?? 't3.large';
    const volumeSizeGiB = Number(this.node.tryGetContext('volumeSize') ?? 30);
    const sshCidr = (this.node.tryGetContext('allowedSshCidr') as string) ?? '0.0.0.0/0';
    const keyName = this.node.tryGetContext('keyName') as string | undefined;

    // ------------------------------------------------------------------
    // Networking: minimal public VPC (single AZ, no NAT to keep cost low)
    // ------------------------------------------------------------------
    const vpc = new ec2.Vpc(this, 'HvwVpc', {
      maxAzs: 1,
      natGateways: 0,
      subnetConfiguration: [
        {
          name: 'public',
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 24,
        },
      ],
    });

    // ------------------------------------------------------------------
    // Security group: SSH / HTTP / HTTPS only (no 11182)
    // ------------------------------------------------------------------
    const sg = new ec2.SecurityGroup(this, 'HvwSecurityGroup', {
      vpc,
      description: 'HVW server: allow SSH, HTTP and HTTPS',
      allowAllOutbound: true,
    });
    sg.addIngressRule(ec2.Peer.ipv4(sshCidr), ec2.Port.tcp(22), 'SSH');
    sg.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(80), 'HTTP');
    sg.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(443), 'HTTPS');

    // ------------------------------------------------------------------
    // IAM role (Session Manager access, no bastion required)
    // ------------------------------------------------------------------
    const role = new iam.Role(this, 'HvwInstanceRole', {
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    // ------------------------------------------------------------------
    // AMI: Ubuntu Server 24.04 LTS (amd64) via Canonical's public SSM param
    // ------------------------------------------------------------------
    const ubuntu = ec2.MachineImage.fromSsmParameter(
      '/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id',
      { os: ec2.OperatingSystemType.LINUX },
    );

    // ------------------------------------------------------------------
    // User-data bootstrap script
    // ------------------------------------------------------------------
    const userDataScript = fs.readFileSync(
      path.join(__dirname, '..', 'assets', 'user-data.sh'),
      'utf8',
    );
    const userData = ec2.UserData.custom(userDataScript);

    // Optionally automate the SDK install. When an SDK download URL is supplied
    // (context `sdkUrl` or env var HVW_SDK_URL), append a step that downloads,
    // extracts, places and starts the HVW SDK — no manual SCP required. The URL
    // is a short-lived presigned link and is intentionally NOT committed; pass
    // it at deploy time. When omitted, follow the manual SCP steps in the README.
    const sdkUrl = (this.node.tryGetContext('sdkUrl') as string) ?? process.env.HVW_SDK_URL;
    if (sdkUrl) {
      const installScript = fs.readFileSync(
        path.join(__dirname, '..', 'assets', 'install-sdk.sh'),
        'utf8',
      );

      // Optional HVW license key. The SDK ships with a time-limited evaluation
      // license baked into server/node/Config.js; supply a longer-lived key at
      // deploy time (context `hvwLicense` or env var HVW_LICENSE) to override it.
      // When omitted, the Config.js default is left untouched.
      const hvwLicense =
        (this.node.tryGetContext('hvwLicense') as string) ?? process.env.HVW_LICENSE;

      const exports = [`export HVW_SDK_URL='${sdkUrl}'`];
      if (hvwLicense) {
        exports.push(`export HVW_LICENSE='${hvwLicense}'`);
      }
      // user-data.sh runs with `set -x`, and its options carry over because
      // this install script is appended and executed as one combined bash
      // script. Disable command tracing before emitting the exports so the
      // presigned SDK URL and license key are never written to
      // /var/log/cloud-init-output.log in clear text. install-sdk.sh keeps
      // `set -eu` (no -x) so the secret-handling commands stay untraced too.
      userData.addCommands('set +x', ...exports, installScript);
    }

    // Optional existing EC2 key pair for SSH access.
    const keyPair = keyName
      ? ec2.KeyPair.fromKeyPairName(this, 'HvwKeyPair', keyName)
      : undefined;

    // ------------------------------------------------------------------
    // EC2 instance
    // ------------------------------------------------------------------
    const instance = new ec2.Instance(this, 'HvwInstance', {
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: new ec2.InstanceType(instanceTypeCtx),
      machineImage: ubuntu,
      securityGroup: sg,
      role,
      userData,
      userDataCausesReplacement: true,
      keyPair,
      blockDevices: [
        {
          deviceName: '/dev/sda1',
          volume: ec2.BlockDeviceVolume.ebs(volumeSizeGiB, {
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            encrypted: true,
          }),
        },
      ],
    });

    // ------------------------------------------------------------------
    // Elastic IP (stable public address to point your domain at)
    // ------------------------------------------------------------------
    const eip = new ec2.CfnEIP(this, 'HvwEip', {
      domain: 'vpc',
      instanceId: instance.instanceId,
    });

    // ------------------------------------------------------------------
    // Outputs
    // ------------------------------------------------------------------
    new cdk.CfnOutput(this, 'InstanceId', { value: instance.instanceId });
    new cdk.CfnOutput(this, 'ElasticIP', {
      value: eip.ref,
      description: 'Point your domain A record at this address, then run certbot',
    });
    new cdk.CfnOutput(this, 'SshCommand', {
      value: keyName
        ? `ssh -i <path-to-${keyName}.pem> ubuntu@${eip.ref}`
        : '(no keyName provided) use AWS Session Manager: aws ssm start-session --target ' +
          instance.instanceId,
    });
    new cdk.CfnOutput(this, 'SampleUrl', {
      value: `http://${eip.ref}/sample.html`,
      description: 'Reachable after the SDK is installed; use https:// after certbot',
    });
  }
}
