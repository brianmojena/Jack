#!/usr/bin/env python3
"""Runs scripts/jack-bot against a stub of Jack's local API."""
import json, os, subprocess, sys, tempfile, threading, unittest
from http.server import BaseHTTPRequestHandler, HTTPServer

CLI = os.path.join(os.path.dirname(os.path.abspath(__file__)), "jack-bot")
state = {"polls": 0, "final": {"status": "done", "answer": "hecho"}, "posts": []}


class Stub(BaseHTTPRequestHandler):
    def log_message(self, *args): pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status); self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)

    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer tok":
            return self.reply(401, {"ok": False, "error": "Invalid token."})
        if self.path == "/v1/agents":
            return self.reply(200, {"ok": True, "agents": [{"id": "abcdef12-0000", "name": "Ada", "busy": False}]})
        state["polls"] += 1
        self.reply(200, {"ok": True, "status": "running"} if state["polls"] < 2 else {"ok": True, **state["final"]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        state["posts"].append((self.path, body))
        if "/nadie/" in self.path:
            return self.reply(404, {"ok": False, "error": "No agent matches."})
        self.reply(202, {"ok": True, "delivery_id": "d1", "status": "started"})


class CLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = HTTPServer(("127.0.0.1", 0), Stub)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.dir = tempfile.mkdtemp()
        open(os.path.join(cls.dir, "url"), "w").write("http://127.0.0.1:%d" % cls.server.server_port)
        open(os.path.join(cls.dir, "token"), "w").write("tok")

    @classmethod
    def tearDownClass(cls): cls.server.shutdown()

    def setUp(self): state.update(polls=0, final={"status": "done", "answer": "hecho"}, posts=[])

    def run_cli(self, *args, input=None, directory=None):
        env = {**os.environ, "JACK_BOT_DIR": directory or self.dir}
        return subprocess.run([sys.executable, "-I", CLI, *args], capture_output=True, text=True, env=env, input=input)

    def test_list(self):
        result = self.run_cli("list")
        self.assertEqual(result.returncode, 0); self.assertIn("Ada", result.stdout)

    def test_run_wait_prints_the_answer(self):
        result = self.run_cli("run", "Ada", "-", "--wait", input="haz esto")
        self.assertEqual((result.returncode, result.stdout.strip()), (0, "hecho"))
        self.assertEqual(state["posts"][0][1]["message"], "haz esto")

    def test_json_output(self):
        result = self.run_cli("run", "Ada", "hola", "--wait", "--json")
        data = json.loads(result.stdout)
        self.assertEqual((result.returncode, data["ok"], data["answer"]), (0, True, "hecho"))

    def test_waiting_for_a_person_exits_3(self):
        state["final"] = {"status": "waiting"}
        self.assertEqual(self.run_cli("run", "Ada", "hola", "--wait").returncode, 3)

    def test_failed_turn_exits_1(self):
        state["final"] = {"status": "failed", "error": "boom"}
        result = self.run_cli("run", "Ada", "hola", "--wait")
        self.assertEqual(result.returncode, 1); self.assertIn("boom", result.stderr)

    def test_timeout_exits_4_and_unknown_agent_exits_1(self):
        state["final"] = {"status": "running"}
        self.assertEqual(self.run_cli("run", "Ada", "hola", "--wait", "--timeout", "1s").returncode, 4)
        self.assertEqual(self.run_cli("run", "nadie", "hola").returncode, 1)

    def test_bad_command_line_exits_2_and_missing_jack_exits_5(self):
        self.assertEqual(self.run_cli("run").returncode, 2)
        self.assertEqual(self.run_cli("list", directory=tempfile.mkdtemp()).returncode, 5)

    def test_routine_sends_payload(self):
        result = self.run_cli("routine", "Ada", "build", "exit 1")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(state["posts"][0], ("/v1/agents/Ada/routines/build/run", {"payload": "exit 1", "id": None}))


if __name__ == "__main__":
    unittest.main()
