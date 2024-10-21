#--------------------------------------------------------------- Variables ---------------------------------------------------------------
variable "vpc_cidr" {
  default = "10.0.0.0/16"
}

variable "dmz_subnet_cidr" {
  default = "10.0.1.0/24"
}

variable "app_subnet_cidr" {
  default = "10.0.2.0/24"
}

variable "az" {
  default = "ap-south-1a"
}

variable "instance_type" {
  default = "t2.large"
}

variable "ec2_ami" {
  default = "ami-0e0e417dfa2028266"  # Example ECS-optimized AMI for your region, replace if necessary
}

#--------------------------------------------------------------- VPC Setup ---------------------------------------------------------------
resource "aws_vpc" "gs_project_vpc" {
  cidr_block = var.vpc_cidr
  enable_dns_support = true
  enable_dns_hostnames = true

  tags = {
    Name = "GS-Project-VPC"
  }
}

#------------------------------------------------------------ Internet Gateway ------------------------------------------------------------
resource "aws_internet_gateway" "gs_igw" {
  vpc_id = aws_vpc.gs_project_vpc.id

  tags = {
    Name = "GS-IGW"
  }
}

#------------------------------------------------------------ Route Table ------------------------------------------------------------
resource "aws_route_table" "gs_pub_rt" {
  vpc_id = aws_vpc.gs_project_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gs_igw.id
  }

  tags = {
    Name = "GS-PUB-RT"
  }
}

#------------------------------------------------------------ Public Subnet ------------------------------------------------------------
resource "aws_subnet" "gs_dmz_subnet" {
  vpc_id            = aws_vpc.gs_project_vpc.id
  cidr_block        = var.dmz_subnet_cidr
  availability_zone = var.az

  tags = {
    Name = "GS-PUB-SUBNET"
  }
}

#---------------------------------------------------------- Associate Subnet with Route Table ----------------------------------------------------------
resource "aws_route_table_association" "gs_pub_rt_asso" {
  subnet_id      = aws_subnet.gs_dmz_subnet.id
  route_table_id = aws_route_table.gs_pub_rt.id
}

#--------------------------------------------------------------- NAT Gateway ---------------------------------------------------------------
resource "aws_eip" "gs_nat_eip" {
  domain = "vpc"
}

resource "aws_nat_gateway" "gs_nat" {
  allocation_id = aws_eip.gs_nat_eip.id
  subnet_id     = aws_subnet.gs_dmz_subnet.id
  depends_on    = [aws_internet_gateway.gs_igw]

  tags = {
    Name = "GS-NAT-GW"
  }
}

#------------------------------------------------------------ Private Subnet for Application ------------------------------------------------------------
resource "aws_subnet" "gs_app_subnet" {
  vpc_id            = aws_vpc.gs_project_vpc.id
  cidr_block        = var.app_subnet_cidr
  availability_zone = var.az

  tags = {
    Name = "GS-APP-SUBNET"
  }
}

#---------------------------------------------------------- Associate Private Subnet with NAT Gateway ----------------------------------------------------------
resource "aws_route_table" "gs_pri_rt" {
  vpc_id = aws_vpc.gs_project_vpc.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.gs_nat.id
  }

  tags = {  
    Name = "GS-PRI-RT"
  }
}

resource "aws_route_table_association" "gs_app_pri_rt_asso" {
  subnet_id      = aws_subnet.gs_app_subnet.id
  route_table_id = aws_route_table.gs_pri_rt.id
}

#----------------------------------------------------------- Security Group for Application -----------------------------------------------------------
resource "aws_security_group" "gs_app_sg" {
  vpc_id = aws_vpc.gs_project_vpc.id
  description = "Security Group for Application EC2"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "GS-APP-SG"
  }
}

#----------------------------------------------------------- ECS Cluster -----------------------------------------------------------
resource "aws_ecs_cluster" "gs_app_ecs_cluster" {
  name = "gs-app-ecs-cluster"
}

#----------------------------------------------------------- IAM Role for ECS EC2 -----------------------------------------------------------
resource "aws_iam_role" "ecs_instance_role" {
  name = "ecs_instance_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_instance_role_policy" {
  role       = aws_iam_role.ecs_instance_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "ecs_instance_profile" {
  name = "ecs_instance_profile"
  role = aws_iam_role.ecs_instance_role.name
}

#------------------------------------------------------------ ECS Launch Template ------------------------------------------------------------
resource "aws_launch_template" "ecs_launch_template" {
  name          = "ecs-launch-template"
  image_id      = var.ec2_ami  # ECS-optimized AMI
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.ecs_instance_profile.name
  }

# Start ECS agent with the ECS cluster name in the ecs.config
  user_data = base64encode(<<EOF
#!/bin/bash
echo ECS_CLUSTER=${aws_ecs_cluster.gs_app_ecs_cluster.name} >> /etc/ecs/ecs.config
sudo systemctl enable --now ecs
EOF
  )

#   block_device_mappings {
#     device_name = "/dev/xvda"
#     ebs {
#       volume_size = 8
#     }
#   }

  vpc_security_group_ids = [aws_security_group.gs_app_sg.id]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ECS-Instance"
    }
  }
}

#---------------------------------------------------------- Auto Scaling Group ----------------------------------------------------------
resource "aws_autoscaling_group" "ecs_asg" {
  desired_capacity   = 1
  max_size           = 2
  min_size           = 1
  vpc_zone_identifier = [aws_subnet.gs_app_subnet.id]

  launch_template {
    id      = aws_launch_template.ecs_launch_template.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "ECS-ASG-Instance"
    propagate_at_launch = true
  }
}
resource "aws_ecr_repository" "gs_app_ecs_repository" {
  name = "gs-app-ecs-repository"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = "gs-app-ecs-repository"
  }
}

resource "aws_ecs_task_definition" "gs_ecs_task" {
  family                   = "gs-app-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  container_definitions    = jsonencode([{
    name      = "nginx-container"
    image     = "${aws_ecr_repository.gs_app_ecs_repository.repository_url}:latest"  # Updated reference to ECR repository
    essential = true
    portMappings = [{
      containerPort = 80
      hostPort      = 80
      protocol      = "tcp"
    }]
    #  logConfiguration = {
    #   logDriver = "awslogs"
    #   options = {
    #     awslogs-group         = aws_cloudwatch_log_group.gs_ecs_logs.name
    #     awslogs-region        = "ap-south-1"
    #     awslogs-stream-prefix = "nginx"
    #   }
    # }
    
  }])

  cpu    = "256"
  memory = "512"
}


# #--------------------------------------------------------------- Task Definition ---------------------------------------------------------------
# resource "aws_ecs_task_definition" "gs_ecs_task" {
#   family                   = "gs-app-task"
#   network_mode             = "none"
#   requires_compatibilities = ["EC2"]
#   execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
#   container_definitions    = jsonencode([{
#     name      = "nginx-container"
#     image     = "${aws_ecr_repository.gs_app_ecs_cluster.repository_url}:latest" 
#     essential = true
#     portMappings = [{
#       containerPort = 80
#       hostPort      = 80
#       protocol      = "tcp"
#     }]
    
    
#   }])

#   cpu    = "256"
#   memory = "512"
# }

#--------------------------------------------------------------- Execution Role for ECS Task ---------------------------------------------------------------
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecs_task_execution_role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}



#--------------------------------------------------------------- ECS Service ---------------------------------------------------------------
resource "aws_ecs_service" "gs_ecs_service" {
  name            = "gs-app-service"
  cluster         = aws_ecs_cluster.gs_app_ecs_cluster.id
  task_definition = aws_ecs_task_definition.gs_ecs_task.arn
  desired_count   = 1
  launch_type     = "EC2"
  
  network_configuration {
    subnets          = [aws_subnet.gs_app_subnet.id]
    security_groups  = [aws_security_group.gs_app_sg.id]
    assign_public_ip = false
  }

  depends_on = [aws_ecs_cluster.gs_app_ecs_cluster]
}

 