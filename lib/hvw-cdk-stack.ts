import * as fs from 'fs';
import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import { Construct } from 'constructs';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3assets from 'aws-cdk-lib/aws-s3-assets';

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

    // Optionally deploy a custom web-service redistributable package. There are
    // two mutually exclusive ways to supply it (checked in priority order):
    //
    //   1. webappS3Uri / WEBAPP_S3_URI — an `s3://bucket/key` URI of an archive
    //      you have ALREADY uploaded to your own S3 bucket. CDK does NOT stage or
    //      hash the file; it only grants the instance role s3:GetObject on that
    //      object and user-data downloads it with `aws s3 cp`. This is the right
    //      choice for large archives (multi-GB): CDK assets are read whole via
    //      fs.readFileSync during synth validation, which Node cannot do for
    //      files larger than 2 GiB (ERR_FS_FILE_TOO_LARGE).
    //
    //   2. webappPackage / WEBAPP_PACKAGE — a LOCAL archive path. CDK uploads it
    //      as an S3 asset (convenient, no pre-upload). Only for smaller archives:
    //      a hard size guard below rejects files that would trip the 2 GiB synth
    //      limit and points you at webappS3Uri instead.
    //
    // Both feed the same downstream flow: download the archive to the instance
    // and hand its local path to assets/install-webapp.sh via WEBAPP_ARCHIVE.
    // This is INDEPENDENT of HVW_SDK_URL, but appended AFTER the SDK step so the
    // web-service package runs last (extraction overwrites files placed earlier).
    const webappS3Uri =
      (this.node.tryGetContext('webappS3Uri') as string) ?? process.env.WEBAPP_S3_URI;
    const webappPackage =
      (this.node.tryGetContext('webappPackage') as string) ?? process.env.WEBAPP_PACKAGE;

    if (webappS3Uri && webappPackage) {
      throw new Error(
        'Supply either webappS3Uri (s3://bucket/key of a pre-uploaded archive) or ' +
          'webappPackage (local archive path), not both.',
      );
    }

    // Resolve the archive to an S3 location the instance downloads from. For a
    // local package this is the uploaded CDK asset; for an S3 URI it is the
    // object you pre-uploaded (and the role is granted read access to it).
    let webappS3ObjectUrl: string | undefined;

    if (webappS3Uri) {
      const match = /^s3:\/\/([^/]+)\/(.+)$/.exec(webappS3Uri);
      if (!match) {
        throw new Error(
          `webappS3Uri / WEBAPP_S3_URI must be an s3://bucket/key URI, got: ${webappS3Uri}`,
        );
      }
      const [, bucketName, objectKey] = match;
      // Least privilege: read access to exactly this object, nothing else.
      role.addToPrincipalPolicy(
        new iam.PolicyStatement({
          actions: ['s3:GetObject'],
          resources: [`arn:${this.partition}:s3:::${bucketName}/${objectKey}`],
        }),
      );
      webappS3ObjectUrl = webappS3Uri;
    } else if (webappPackage) {
      const resolvedPackagePath = path.resolve(process.cwd(), webappPackage);
      if (!fs.existsSync(resolvedPackagePath)) {
        throw new Error(
          `webappPackage / WEBAPP_PACKAGE points at a non-existent path: ${resolvedPackagePath}`,
        );
      }

      // Guard against the 2 GiB CDK-asset limit. During synth CDK's validation
      // reads each staged asset whole with fs.readFileSync, which throws
      // ERR_FS_FILE_TOO_LARGE for files larger than 2 GiB. Reject early with an
      // actionable message pointing at the S3-URI path for large archives.
      const maxAssetBytes = 1.9 * 1024 * 1024 * 1024;
      const packageBytes = fs.statSync(resolvedPackagePath).size;
      if (packageBytes > maxAssetBytes) {
        throw new Error(
          `webappPackage is ${(packageBytes / 1024 ** 3).toFixed(2)} GiB, which is too ` +
            'large to bundle as a CDK asset (Node cannot fs.readFileSync files larger ' +
            'than 2 GiB during synth). Upload the archive to your own S3 bucket and ' +
            'pass webappS3Uri=s3://bucket/key instead.',
        );
      }

      const webappAsset = new s3assets.Asset(this, 'WebappPackage', {
        path: resolvedPackagePath,
      });
      webappAsset.grantRead(role);
      webappS3ObjectUrl = webappAsset.s3ObjectUrl;
    }

    if (webappS3ObjectUrl) {
      const webappInstallScript = fs.readFileSync(
        path.join(__dirname, '..', 'assets', 'install-webapp.sh'),
        'utf8',
      );

      // Download the archive to the instance using the EC2 role credentials,
      // then hand the local path to install-webapp.sh via WEBAPP_ARCHIVE.
      // (UserData.custom() doesn't support addS3DownloadCommand, so the aws
      // s3 cp command is emitted explicitly. The EC2 default region from IMDS
      // matches the asset's / object's bucket region.)
      const localArchive = '/tmp/webapp-package/archive';
      userData.addCommands(
        'mkdir -p /tmp/webapp-package',
        `aws s3 cp '${webappS3ObjectUrl}' '${localArchive}'`,
        `export WEBAPP_ARCHIVE='${localArchive}'`,
        webappInstallScript,
      );
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
