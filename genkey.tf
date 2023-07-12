module "cf_key" {
	source  = "sashee/ssm-generated-value/aws"
	parameter_name = "/cfkey-${random_id.id.hex}"
	code = <<EOF
import crypto from "node:crypto";
import {promisify} from "node:util";

export const generate = async () => {
	const {publicKey, privateKey} = await promisify(crypto.generateKeyPair)(
		"rsa",
		{
			modulusLength: 2048,
			publicKeyEncoding: {
				type: 'spki',
				format: 'pem',
			},
			privateKeyEncoding: {
				type: 'pkcs8',
				format: 'pem',
			},
		},
	);
	return {
		value: privateKey,
		outputs: {
			publicKey,
		}
	};
}

export const cleanup = () => {};
EOF
}

