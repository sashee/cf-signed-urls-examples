import {getSignedUrl} from "@aws-sdk/cloudfront-signer";
import {SSMClient, GetParameterCommand} from "@aws-sdk/client-ssm";
import crypto from "node:crypto";
import {KMSClient, DecryptCommand} from "@aws-sdk/client-kms";
import {Buffer} from "node:buffer";

const cacheOperation = (fn, cacheTime) => {
	let lastRefreshed = undefined;
	let lastResult = undefined;
	let queue = Promise.resolve();
	return () => {
		const res = queue.then(async () => {
			const currentTime = new Date().getTime();
			if (lastResult === undefined || lastRefreshed + cacheTime < currentTime) {
				lastResult = await fn();
				lastRefreshed = currentTime;
			}
			return lastResult;
		});
		queue = res.catch(() => {});
		return res;
	};
};

const getCfPrivateKey = cacheOperation(() => new SSMClient().send(new GetParameterCommand({Name: process.env.CF_PRIVATE_KEY_PARAMETER, WithDecryption: true})), 15 * 1000);

const getKmsPrivateKey = cacheOperation(() => new KMSClient().send(new DecryptCommand({
	CiphertextBlob: Buffer.from(process.env.PRIVATE_KEY_CIPHERTEXT, "base64"),
	EncryptionContext: {USE: "CF"},
	KeyId: process.env.KMS_KEY_ID,
})), 15 * 1000);

const roundTo = 5 * 60 * 1000; // 5 minutes

export const handler = async (event) => {
	if (event.rawPath.match(/^\/?protected\//) === null) {
		const url = `https://${process.env.DISTRIBUTION_DOMAIN}/protected/path`;
		const expiration = new Date(Math.floor(new Date().getTime() / roundTo) * roundTo + 15 * 60 * 1000); // 15 minutes, effective range: 10-15 minutes
		const sdkSignedUrl = await (async () => {
			const privateKey = (await getCfPrivateKey()).Parameter.Value;
			return getSignedUrl({
				url,
				keyPairId: process.env.KEYPAIR_ID,
				dateLessThan: expiration,
				privateKey,
			});
		})();
		const cryptoSignedUrl = await (async () => {
			const privateKey = (await getCfPrivateKey()).Parameter.Value;
			const expires = Math.round(expiration.getTime() / 1000);
			const policy = {
				Statement: [
					{
						Resource: url,
						Condition: {
							DateLessThan: {
								"AWS:EpochTime": expires,
							}
						}
					}
				]
			};
			const sign = crypto.createSign("SHA1");
			sign.write(JSON.stringify(policy));
			sign.end();
			const signature = sign.sign(privateKey).toString("base64");
			return `${url}?Expires=${expires}&Signature=${signature.replaceAll("+", "-").replaceAll("=", "_").replaceAll("/", "~")}&Key-Pair-Id=${process.env.KEYPAIR_ID}`;
		})();
		const kmsSignedUrl = await (async () => {
			const privateKey = (await getKmsPrivateKey()).Plaintext;
			const inPem = `-----BEGIN PRIVATE KEY-----\n${Buffer.from(privateKey).toString("base64")}\n-----END PRIVATE KEY-----\n`;
			return getSignedUrl({
				url,
				keyPairId: process.env.KMS_KEYPAIR_ID,
				dateLessThan: expiration,
				privateKey: inPem,
			});
		})();
		return {
			statusCode: 200,
			headers: {
				"Content-Type": "text/html",
			},
			body: `
<!DOCTYPE html>
<html lang="en">
  <head>
    <meta charset="UTF-8">
  </head>
  <body>
	SDK signed URL:
	<iframe src="${sdkSignedUrl}"></iframe>
	Crypto:
	<iframe src="${cryptoSignedUrl}"></iframe>
	KMS:
	<iframe src="${kmsSignedUrl}"></iframe>
  </body>
</html>
			`,
		};
	}else {
		return JSON.stringify(event, undefined, 4);
	}
};

