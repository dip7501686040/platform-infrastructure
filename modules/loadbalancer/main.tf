locals {
  # Floci's EKS node groups are metadata-only -- CreateNodegroup just stores
  # config, it never calls RunInstances, so no real EC2 instance backs the
  # node group there (confirmed against a live Floci instance: `aws ec2
  # describe-instances` shows nothing for it). The k3s "node" is really just
  # the floci-eks-<cluster> Docker container. target-type=instance has
  # nothing to attach to locally -- ip is the only viable type, registering
  # that container's own bridge IP directly. Confirmed working end-to-end
  # against a live Floci instance: ALB listener -> ip target (container IP +
  # NodePort) -> k3s NodePort -> pod, HTTP 200.
  #
  # Real AWS keeps target-type=instance so registration can ride
  # aws_autoscaling_attachment, which keeps targets in sync continuously as
  # the group scales -- not just at the next terraform apply, the way an
  # ip-per-instance data lookup would be.
  target_type = var.manage_floci ? "ip" : "instance"
}

# Real AWS only -- Floci doesn't enforce security groups against actual
# routing (ELBv2's SetSecurityGroups just stores the IDs), so there's
# nothing for this to gate locally.
resource "aws_security_group" "alb" {
  count = var.manage_floci ? 0 : 1

  name_prefix = "${var.name_prefix}-alb-"
  description = "ALB security group -- inbound app traffic from the internet, all egress"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.services
    content {
      description = "${ingress.key} listener"
      from_port   = ingress.value.listener_port
      to_port     = ingress.value.listener_port
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-alb-sg" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group_rule" "nodes_from_alb" {
  for_each = var.manage_floci ? {} : var.services

  type                     = "ingress"
  description              = "ALB -> node NodePort for ${each.key}"
  from_port                = each.value.node_port
  to_port                  = each.value.node_port
  protocol                 = "tcp"
  security_group_id        = var.cluster_security_group_id
  source_security_group_id = aws_security_group.alb[0].id
}

resource "aws_lb" "this" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false
  subnets            = var.public_subnet_ids
  security_groups    = var.manage_floci ? null : [aws_security_group.alb[0].id]

  tags = var.tags
}

resource "aws_lb_target_group" "this" {
  for_each = var.services

  name        = "${each.key}-tg"
  port        = each.value.node_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = local.target_type

  health_check {
    path                = each.value.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200-399"
  }

  tags = var.tags
}

resource "aws_lb_target_group_attachment" "floci" {
  for_each = var.manage_floci ? var.services : {}

  target_group_arn = aws_lb_target_group.this[each.key].arn
  target_id        = var.static_ip
  port             = each.value.node_port
}

resource "aws_autoscaling_attachment" "nodes" {
  for_each = var.manage_floci ? {} : var.services

  autoscaling_group_name = var.node_group_asg_name
  lb_target_group_arn    = aws_lb_target_group.this[each.key].arn
}

resource "aws_lb_listener" "this" {
  for_each = var.services

  load_balancer_arn = aws_lb.this.arn
  port              = each.value.listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  tags = var.tags
}
