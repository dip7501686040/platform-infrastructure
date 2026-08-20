output "public_ip" {
  value = aws_instance.jenkins.public_ip
}

output "instance_id" {
  value = aws_instance.jenkins.id
}

output "ssh_private_key_path" {
  value = local_sensitive_file.jenkins_ssh_key.filename
}

output "admin_password_path" {
  value = local_sensitive_file.jenkins_admin_password.filename
}
