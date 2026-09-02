cert-gen:
	@mkdir -p ./cert
	@openssl req -x509 -newkey rsa:4096 -keyout ./cert/server.key -out ./cert/server.crt -days 365 -nodes -subj "/C=ID/ST=Jakarta/L=Jakarta/O=docs-digihome/OU=IT/CN=digihome"