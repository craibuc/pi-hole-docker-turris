image:

	docker volume create --name pihole-etc-pihole
	docker volume create --name pihole-etc-dnsmasq.d

run:

	docker run -d \
		--name pihole \
		-v pihole-etc-pihole:/etc/pihole/ \
		-v pihole-etc-dnsmasq.d:/etc/dnsmasq.d/ \
		-p 53:53/tcp -p 53:53/udp \
		-p 80:80 \
		-p 443:443 \
		-e TZ="America/Chicago" \
		--dns=127.0.0.1 --dns=1.1.1.1 \
		--restart=unless-stopped \
		--hostname pi.hole \
		-e VIRTUAL_HOST="pi.hole" \
		-e PROXY_LOCATION="pi.hole" \
		-e ServerIP="127.0.0.1" \
		pihole/pihole:latest

	docker logs -f pihole
