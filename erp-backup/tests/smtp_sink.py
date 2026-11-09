# A minimal SMTP server for tests/notify-mail.sh (stands in for Zoho or any provider). Plain SMTP, AUTH PLAIN and
# LOGIN. Each delivered message is appended to OUT as one JSON line: the login it was sent with, MAIL FROM, RCPT TO
# and the raw message. Usage: python3 smtp_sink.py PORT OUT
import base64, json, socketserver, sys

PORT, OUT = int(sys.argv[1]), sys.argv[2]


class H(socketserver.StreamRequestHandler):
	def say(self, line):
		self.wfile.write((line + "\r\n").encode())

	def handle(self):
		auth, frm, rcpt = None, None, []
		self.say("220 sink ESMTP")
		while True:
			raw = self.rfile.readline()
			if not raw:
				return
			line = raw.decode(errors="replace").rstrip("\r\n")
			cmd = line.split(" ", 1)[0].upper()
			if cmd in ("EHLO", "HELO"):
				self.wfile.write(b"250-sink\r\n250-AUTH PLAIN LOGIN\r\n250 OK\r\n")
			elif cmd == "AUTH":
				parts = line.split(" ")
				if parts[1].upper() == "PLAIN":
					blob = parts[2] if len(parts) > 2 else None
					if blob is None:
						self.say("334 ")
						blob = self.rfile.readline().decode().strip()
					_, user, pw = base64.b64decode(blob).decode().split("\0")
				else:
					self.say("334 VXNlcm5hbWU6")
					user = base64.b64decode(self.rfile.readline().strip()).decode()
					self.say("334 UGFzc3dvcmQ6")
					pw = base64.b64decode(self.rfile.readline().strip()).decode()
				auth = [user, pw]
				self.say("235 OK")
			elif cmd == "MAIL":
				frm = line.split(":", 1)[1].strip().strip("<>").split(">")[0]
				self.say("250 OK")
			elif cmd == "RCPT":
				rcpt.append(line.split(":", 1)[1].strip().strip("<>").split(">")[0])
				self.say("250 OK")
			elif cmd == "DATA":
				self.say("354 go")
				body = []
				while True:
					l = self.rfile.readline().decode(errors="replace")
					if l.rstrip("\r\n") == ".":
						break
					body.append(l)
				with open(OUT, "a") as f:
					f.write(json.dumps({"auth": auth, "from": frm, "rcpt": rcpt, "data": "".join(body)}) + "\n")
				self.say("250 queued")
				frm, rcpt = None, []
			elif cmd == "QUIT":
				self.say("221 bye")
				return
			else:
				self.say("250 OK")


class S(socketserver.ThreadingTCPServer):
	allow_reuse_address = True


S(("127.0.0.1", PORT), H).serve_forever()
