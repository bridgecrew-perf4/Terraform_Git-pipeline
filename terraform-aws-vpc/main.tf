terraform {
    required_providers {
        aws = {
            source = "hashicorp/aws"
            version = "~> 3.0"
        }
    }
}

# Init Credentials profile and Region
provider "aws" {
  profile = "default"
  region = "us-east-1"
  shared_credentials_file = "credentials"
}

//Create the VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/27"
  instance_tenancy     = "default"
  enable_dns_support   = "true"
  enable_dns_hostnames = "true"
tags = {
  Name = "main"
  }
}

// Create the public-subnet"
resource "aws_subnet" "public-subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.0/28"
  map_public_ip_on_launch = "true"
  availability_zone       = "us-east-1"

  tags = {
    Name = "public-subnet"
  }
}

// Create the private-subnet
resource "aws_subnet" "private-subnet" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.0.16/28"
  map_public_ip_on_launch = "false"
  availability_zone       = "us-east-1"

  tags = {
    Name = "private-subnet"
  }
}

// Create the Security Grup
resource "aws_security_grup" "SG_main" {
  vpc_id                  = "${aws_vpc.main.id}"
  Name                    = "SG_main"
  description             = "default VPC Security Grup"
  ingress {
      from_port           = 22
      to_port             = 22
      protocol            = "tcp"
      cidr_block          = ["0.0.0.0/0"]
  }
  ingress {
      from_port           = 80
      to_port             = 80
      protocol            = "tcp"
      cidr_block          = ["0.0.0.0/0"]
  }
  ingress {
      from_port           = 443
      to_port             = 443
      protocol            = "tcp"
      cidr_block          = ["0.0.0.0/0"]
  }
  egress {
      from_port           = 0
      to_port             = 0
      protocol            = "-1"
      cidr_block          = ["0.0.0.0/0"]
  }
  tags = {
      Name = "SG_main"
  }
}

//Create the Internet Gateway
resource "aws_internet_gateway" "internet-gw" {
  vpc_id = aws_vpc.main.id

tags = {
    Name = "internet-gw"
  }
}

//Create the public Route Table
resource "aws_route_table" "public-rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet-gw.id
  }
}

//Associate the Route Table with the Subnet
resource "aws_route_table_association" "public-rta" {
  subnet_id      = aws_subnet.public-subnet.id
  route_table_id = aws_route_table.public-rt.id
}

//Create the EIP NAT
resource "aws_eip" "nat" {
  vpc = true
}

//Create NAT Gateway and Associated 
resource "aws_nat_gateway" "nat-gw" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public-subnet.id
  depends_on    = [aws_internet_gateway.internet-gw]
}

//Create the  private Route Table
resource "aws_route_table" "private-rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat-gw.id
  }
}

//Associate the Route Table with the Subnet
resource "aws_route_table_association" "private-rta" {
  subnet_id      = aws_subnet.private-subnet.id
  route_table_id = aws_route_table.private-rt.id
}


//Auto Scaling Grup
data "aws_ami" "ubuntu" {
  most_recent = true

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-trusty-14.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["099720109477"] # Canonical
}

resource "aws_launch_configuration" "agent-lc" {
  name_prefix                 = "agent-lc"
  image_id                    = data.aws_ami.ubuntu.id
  instance_type               = "t2.medium"
  associate_public_ip_address = false
  subnet_id                   = aws_subnet.private-subnet.id
  security_groups             = [aws_security_group.SG_main.id]
  
  lifecycle {
    create_before_destroy = true
  }

  root_block_device {
     volume_type = "gp2"
     volume_size = "50"
  }  
}

resource "aws_autoscaling_group" "agents" {
  name                 = "agents"
  launch_configuration = aws_launch_configuration.agent-lc.name
  min_size             = 2
  max_size             = 5
  health_check_type    = "EC2"
  desired_capacity          = 2
  wait_for_capacity_timeout = "10m"

  lifecycle {
    create_before_destroy = true
  }

}

resource "aws_autoscaling_policy" "agents-scale-up" {
    name = "agents-scale-up"
    scaling_adjustment = 1
    adjustment_type = "ChangeInCapacity"
    cooldown = 300
    autoscaling_group_name = aws_autoscaling_group.agents.name
}

resource "aws_autoscaling_policy" "agents-scale-down" {
    name = "agents-scale-down"
    scaling_adjustment = -1
    adjustment_type = "ChangeInCapacity"
    cooldown = 300
    autoscaling_group_name = aws_autoscaling_group.agents.name
}

resource "aws_cloudwatch_metric_alarm" "memory-high" {
    alarm_name = "mem-util-high-agents"
    comparison_operator = "GreaterThanOrEqualToThreshold"
    evaluation_periods = "2"
    metric_name = "MemoryUtilization"
    namespace = "System/Linux"
    period = "300"
    statistic = "Average"
    threshold = "40"
    alarm_description = "This metric monitors ec2 memory for high utilization on agent hosts"
    alarm_actions = [
        aws_autoscaling_policy.agents-scale-up.arn
    ]
    dimensions = {
        AutoScalingGroupName = aws_autoscaling_group.agents.name
    }
}

resource "aws_cloudwatch_metric_alarm" "memory-low" {
    alarm_name = "mem-util-low-agents"
    comparison_operator = "LessThanOrEqualToThreshold"
    evaluation_periods = "2"
    metric_name = "MemoryUtilization"
    namespace = "System/Linux"
    period = "300"
    statistic = "Average"
    threshold = "20"
    alarm_description = "This metric monitors ec2 memory for low utilization on agent hosts"
    alarm_actions = [
        aws_autoscaling_policy.agents-scale-down.arn
    ]
    dimensions = {
        AutoScalingGroupName = aws_autoscaling_group.agents.name
    }
}








