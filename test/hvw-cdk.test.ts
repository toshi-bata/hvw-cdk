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
