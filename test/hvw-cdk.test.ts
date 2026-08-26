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
