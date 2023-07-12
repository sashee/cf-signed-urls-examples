resource "aws_kms_key" "key" {
}

resource "terraform_data" "gen_keys" {
  provisioner "local-exec" {
    command = <<EOT
aws kms generate-data-key-pair-without-plaintext --key-id $KEY_ARN --key-pair-spec RSA_2048 --encryption-context "USE=CF" > $TARGET_FILE
EOT
		environment = {
			KEY_ARN = aws_kms_key.key.arn
			TARGET_FILE = "/tmp/keys-${random_id.id.hex}.json"
		}
  }
}

data "local_file" "key" {
  filename = "/tmp/keys-${random_id.id.hex}.json"
	depends_on = [
		terraform_data.gen_keys
	]
}

