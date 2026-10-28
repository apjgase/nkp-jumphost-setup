"""Fake Prism Central + Harbor over TLS for the shell tests. argv: portfile statefile; env FAKE_REPOS, FAKE_PUBLIC."""
import json
import os
import ssl
import sys
import threading
from http.server import ThreadingHTTPServer

sys.path.insert(0, os.environ["NKP_DIR"])
import test_nkp_lab as t  # noqa: E402

fake = t.Fake()
fake.projects["nkp"]["repo_count"] = int(os.environ.get("FAKE_REPOS", "3"))
fake.projects["nkp"]["metadata"]["public"] = os.environ.get("FAKE_PUBLIC", "false")
state_file = sys.argv[2]
lock = threading.Lock()


class H(t.Handler):
    def route(self):
        super().route()
        with lock, open(state_file, "w") as f:
            json.dump({"puts": fake.puts, "projects": fake.projects, "robot": fake.created_robot,
                       "deleted": fake.deleted, "path": self.path}, f)

    do_GET = do_POST = do_PUT = do_DELETE = do_HEAD = route


H.fake = fake
srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
here = os.path.dirname(os.path.abspath(__file__))
ctx.load_cert_chain(os.path.join(here, "cert.pem"), os.path.join(here, "key.pem"))
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
with open(sys.argv[1], "w") as f:
    f.write(str(srv.server_port))
srv.serve_forever()
