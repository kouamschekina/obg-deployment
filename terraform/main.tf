module "eip" {
  source      = "./modules/eip"
  name        = "nat-eip"
  environment = var.environment
}

module "vpc" {
  source = "./modules/vpc"

  vpc_name         = "obgdeb-vpc-2025"
  vpc_cidr         = "10.0.0.0/16"
  azs              = ["eu-north-1a"]
  private_subnets  = ["10.0.1.0/24"]
  public_subnets   = ["10.0.101.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  reuse_nat_ips        = true
  external_nat_ip_ids  = [module.eip.id]

  tags = {
    Environment = "dev"
    Terraform   = "true"
  }
}

module "iam" {
  source = "./modules/iam"

  role_name             = "obgdeb-ec2-role"
  instance_profile_name = "obgdeb-ec2-profile"

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

module "security_group" {
  source = "./modules/security-group"

  name        = "obgdeb-app-sg"
  description = "Security group for OBG application"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = []
  egress_with_cidr_blocks  = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      description = "All outbound traffic"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

module "alb_security_group" {
  source = "./modules/security-group"

  name        = "obgdeb-alb-sg"
  description = "Allow HTTP and HTTPS to ALB"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      from_port   = 80
      to_port     = 80
      protocol    = "tcp"
      description = "HTTP"
      cidr_blocks = "0.0.0.0/0"
    },
    {
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      description = "HTTPS"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  egress_with_cidr_blocks = [
    {
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      description = "All outbound traffic"
      cidr_blocks = "0.0.0.0/0"
    }
  ]

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_lb" "app" {
  name               = "obgdeb-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [module.alb_security_group.security_group_id]
  subnets            = module.vpc.public_subnets

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "obgdeb-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = module.vpc.vpc_id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    matcher             = "200-399"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "redirect"
    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-2016-08"
  certificate_arn   = module.acm.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

resource "aws_lb_target_group_attachment" "app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = module.ec2.instance_id
  port             = 80
}

resource "aws_security_group_rule" "allow_alb_to_ec2" {
  type                     = "ingress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  security_group_id        = module.security_group.security_group_id
  source_security_group_id = module.alb_security_group.security_group_id
  description              = "Allow ALB to reach EC2"
}

module "ec2" {
  source = "./modules/ec2"

  name                    = "obgdeb-app-server"
  ami_id                  = data.aws_ami.ubuntu.id
  instance_type           = "t3.large"
  subnet_id               = module.vpc.private_subnets[0]
  security_group_id       = module.security_group.security_group_id
  iam_instance_profile_name = module.iam.instance_profile_name
  user_data_path          = "${path.module}/scripts/bootstrap.sh"
  associate_public_ip_address = false

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
  depends_on = [module.vpc, module.iam, module.security_group]
}

module "acm" {
  source = "./modules/acm"

  domain_name = "obgdeb.com"
  subject_alternative_names = ["*.obgdeb.com"]

  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
  depends_on = [module.vpc]
}

module "dns" {
  source = "./modules/dns"

  domain_name = "obgdeb.com"
  target_domain_name = aws_lb.app.dns_name
  target_zone_id = aws_lb.app.zone_id
  certificate_domain_validation_options = module.acm.certificate_domain_validation_options
  zone_id = "Z00518373C54T0KEYAIGH"
  depends_on = [module.acm]
}

module "cloudwatch" {
  source = "./modules/cloudwatch"

  instance_id   = module.ec2.instance_id
  instance_name = "obgdeb-app-server"
  alarms = {
    cpu_utilization = {
      name                = "HighCPUUtilization"
      comparison_operator = "GreaterThanThreshold"
      evaluation_periods  = 2
      metric_name         = "CPUUtilization"
      namespace           = "AWS/EC2"
      period              = 300
      statistic           = "Average"
      threshold           = 80
      description         = "Alarm when CPU exceeds 80%"
      alarm_actions       = []
      ok_actions          = []
    }
  }
  tags = {
    Environment = var.environment
    Terraform   = "true"
  }
  depends_on = [module.ec2]
}



