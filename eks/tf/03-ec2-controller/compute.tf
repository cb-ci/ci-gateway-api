# =============================================================================
# EC2 INSTANCE — replaces steps 6-7 of 07-createEC2WithController.sh
# =============================================================================
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_instance" "this" {
  ami                    = data.aws_ssm_parameter.al2023.value
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  key_name               = var.ssh_key_name != "" ? var.ssh_key_name : null

  # user_data_replace_on_change means a bootstrap change (e.g. a new
  # controller_image) forces a fresh instance rather than silently drifting
  # from what's actually running — the original script's ExecStartPre
  # (docker rm -f) + systemd restart only take effect on a reboot/redeploy.
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/user_data.sh.tpl", {
    controller_port  = var.controller_port
    controller_image = var.controller_image
  })

  root_block_device {
    volume_size           = var.volume_size_gb
    volume_type           = "gp3"
    delete_on_termination = true
  }

  metadata_options {
    http_tokens = "required"
  }

  tags = merge(local.tags, { Name = local.instance_name })
}
