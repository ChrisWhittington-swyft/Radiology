# VPC resources: This will create 1 VPC with 4 Subnets, 1 Internet Gateway, 4 Route Tables. 


  # NETWORK CONFIGURATION
  # ----------------------
resource "aws_vpc" "terraform_vpc" {
  cidr_block       = var.vpc_cidr
  instance_tenancy = "default"

  tags = {
    Name = "Terraform-vpc"
  }

  enable_dns_hostnames = true
  enable_dns_support   = true
}

# Get AZs
 data "aws_availability_zones" "AZs" {
   state    = "available"
 } 


# public subnet 1
resource "aws_subnet" "public_subnet_1" {
  depends_on = [
    aws_vpc.terraform_vpc,
  ]

  vpc_id     = aws_vpc.terraform_vpc.id
  cidr_block = var.public_subnet_az_1_CIDR

  availability_zone = element(data.aws_availability_zones.AZs.names, 2)

  tags = {
    Name                              = "public-subnet-1"
    "kubernetes.io/role/elb"          = "1"
  }

  map_public_ip_on_launch = true
}

# public subnet 2
resource "aws_subnet" "public_subnet_2" {
  depends_on = [
    aws_vpc.terraform_vpc,
  ]

  vpc_id     = aws_vpc.terraform_vpc.id
  cidr_block = var.public_subnet_az_2_CIDR

  availability_zone = element(data.aws_availability_zones.AZs.names, 3)

  tags = {
    Name                              = "public-subnet-2"
    "kubernetes.io/role/elb"          = "1"
  }

  map_public_ip_on_launch = true
}

# private subnet 1
resource "aws_subnet" "private_subnet_1" {
  depends_on = [
    aws_vpc.terraform_vpc,
  ]

  vpc_id     = aws_vpc.terraform_vpc.id
  cidr_block = var.private_subnet_az_1_CIDR

  availability_zone = element(data.aws_availability_zones.AZs.names, 2)

  tags = {
    Name                              = "private-subnet-1"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# private subnet 2
resource "aws_subnet" "private_subnet_2" {
  depends_on = [
    aws_vpc.terraform_vpc,
  ]

  vpc_id     = aws_vpc.terraform_vpc.id
  cidr_block = var.private_subnet_az_2_CIDR

  availability_zone = element(data.aws_availability_zones.AZs.names, 3)

  tags = {
    Name                              = "private-subnet-2"
    "kubernetes.io/role/internal-elb" = "1"
  }
}

# internet gateway
resource "aws_internet_gateway" "internet_gateway" {
  depends_on = [
    aws_vpc.terraform_vpc,
  ]

  vpc_id = aws_vpc.terraform_vpc.id

  tags = {
    Name = "internet-gateway"
  }
}


# route table with target as internet gateway
resource "aws_route_table" "Public_route_table" {
  depends_on = [
    aws_vpc.terraform_vpc,
    aws_internet_gateway.internet_gateway,
  ]

  vpc_id = aws_vpc.terraform_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.internet_gateway.id
  }

  tags = {
    Name = "Public-route-table"
  }
}

# associate route table 1 to public subnet
resource "aws_route_table_association" "associate_routetable_to_public_subnet_1" {
  depends_on = [
    aws_subnet.public_subnet_1,
    aws_route_table.Public_route_table,
  ]
  subnet_id      = aws_subnet.public_subnet_1.id
  route_table_id = aws_route_table.Public_route_table.id
}

# associate route table 2 to public subnet
resource "aws_route_table_association" "associate_routetable_to_public_subnet_2" {
  depends_on = [
    aws_subnet.public_subnet_2,
    aws_route_table.Public_route_table,
  ]
  subnet_id      = aws_subnet.public_subnet_2.id
  route_table_id = aws_route_table.Public_route_table.id
}

# elastic ip
resource "aws_eip" "nat_elastic_ip" {
  domain = "vpc"
  tags = {
    Name = "NAT"
  }
}

# NAT gateway
resource "aws_nat_gateway" "nat_gateway" {
  depends_on = [
    aws_subnet.public_subnet_1,
    aws_eip.nat_elastic_ip,
  ]
  allocation_id = aws_eip.nat_elastic_ip.id
  subnet_id     = aws_subnet.public_subnet_1.id

  tags = {
    Name = "nat-gateway"
  }
}

# route table with target as NAT gateway
resource "aws_route_table" "Private_route_table" {
  depends_on = [
    aws_vpc.terraform_vpc,
    aws_nat_gateway.nat_gateway,
  ]

  vpc_id = aws_vpc.terraform_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat_gateway.id
  }

  tags = {
    Name = "Private-route-table"
  }
}

# associate route table to private subnet 1
resource "aws_route_table_association" "associate_routetable_to_private_subnet_1" {
  depends_on = [
    aws_subnet.private_subnet_1,
    aws_route_table.Private_route_table,
  ]
  subnet_id      = aws_subnet.private_subnet_1.id
  route_table_id = aws_route_table.Private_route_table.id
}

# associate route table to private subnet 2
resource "aws_route_table_association" "associate_routetable_to_private_subnet_2" {
  depends_on = [
    aws_subnet.private_subnet_2,
    aws_route_table.Private_route_table,
  ]
  subnet_id      = aws_subnet.private_subnet_2.id
  route_table_id = aws_route_table.Private_route_table.id
}
