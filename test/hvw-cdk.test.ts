import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { HvwCdkStack } from '../lib/hvw-cdk-stack';

test('creates an EC2 instance and an Elastic IP', () => {
  const app = new cdk.App();
  const stack = new HvwCdkStack(app, 'TestStack');
  const template = Template.fromStack(stack);

  template.resourceCountIs('AWS::EC2::Instance', 1);
  template.resourceCountIs('AWS::EC2::EIP', 1);
});

test('security group exposes 80 and 443 but not 11182', () => {
  const app = new cdk.App();
  const stack = new HvwCdkStack(app, 'TestStack2');
  const template = Template.fromStack(stack);

  const sgs = template.findResources('AWS::EC2::SecurityGroup');
  const ingress = Object.values(sgs).flatMap(
    (r: any) => r.Properties.SecurityGroupIngress ?? [],
  );
  const ports = ingress.map((i: any) => i.FromPort);
  expect(ports).toEqual(expect.arrayContaining([22, 80, 443]));
  expect(ports).not.toContain(11182);
});

test('user-data reverse proxy whitelists the HVW ports only', () => {
  const app = new cdk.App();
  const stack = new HvwCdkStack(app, 'TestStack3');
  const template = Template.fromStack(stack);

  const instances = template.findResources('AWS::EC2::Instance');
  const userData = Object.values(instances)[0].Properties.UserData['Fn::Base64'];

  // Port-limited regex locations must be present ...
  expect(userData).toContain('location ~ ^/wsproxy/(11182|11180)$');
  expect(userData).toContain('location ~ ^/httpproxy/(11182|11180)/(.*)$');
  // ... and the old unrestricted proxy_pass must be gone.
  expect(userData).not.toContain('proxy_pass http://127.0.0.1:$1;');
});

test('custom web-service package is deployed after sample.html and the SDK, independent of sdkUrl', () => {
  const app = new cdk.App({
    context: {
      webappPackage: 'test/fixtures/webapp',
      sdkUrl: 'https://example.invalid/HOOPS_Visualize_Web_2026.6.0_Linux_x86-64.tar.gz',
    },
  });
  const stack = new HvwCdkStack(app, 'TestStack4');
  const template = Template.fromStack(stack);

  const instances = template.findResources('AWS::EC2::Instance');
  // With the S3 asset, user-data becomes an Fn::Join of tokens, so stringify
  // the whole structure and assert on the literal script fragments it contains.
  const userData = JSON.stringify(Object.values(instances)[0].Properties.UserData);

  const sampleIdx = userData.indexOf('containerId');
  const sdkIdx = userData.indexOf('HVW SDK installed under');
  const webappIdx = userData.indexOf('/tmp/install-webapp.sh');

  // All three steps are present ...
  expect(sampleIdx).toBeGreaterThanOrEqual(0);
  expect(sdkIdx).toBeGreaterThanOrEqual(0);
  expect(webappIdx).toBeGreaterThanOrEqual(0);
  // ... and the web-service package is fetched/extracted LAST (after sample.html
  // and the SDK/demo-app), so it can overwrite/update those files.
  expect(webappIdx).toBeGreaterThan(sampleIdx);
  expect(webappIdx).toBeGreaterThan(sdkIdx);
});

test('custom web-service package works without an SDK URL (independent of HVW_SDK_URL)', () => {
  const app = new cdk.App({
    context: { webappPackage: 'test/fixtures/webapp' },
  });
  const stack = new HvwCdkStack(app, 'TestStack5');
  const template = Template.fromStack(stack);

  const instances = template.findResources('AWS::EC2::Instance');
  const userData = JSON.stringify(Object.values(instances)[0].Properties.UserData);

  // The web-service install step is present even though sdkUrl is unset ...
  expect(userData).toContain('/tmp/install-webapp.sh');
  // ... and the SDK step is absent.
  expect(userData).not.toContain('HVW SDK installed under');
});
