# Simple Flask app — this is what we will containerize and deploy
# Blue deployment returns blue response, Green returns green
# The COLOR env variable is set in Kubernetes deployment manifest

from flask import Flask, jsonify
import os, datetime

app = Flask(__name__)

COLOR   = os.environ.get("COLOR", "blue")     # injected by K8s
VERSION = os.environ.get("VERSION", "1.0.0")  # image tag from Jenkins

@app.route("/")
def home():
    return jsonify({
        "app":        "AWS DevOps Blue-Green Demo",
        "color":      COLOR,
        "version":    VERSION,
        "message":    f"Hello from {COLOR.upper()} deployment!",
        "timestamp":  datetime.datetime.utcnow().isoformat()
    })

@app.route("/health")
def health():
    # Kubernetes liveness + readiness probe hits this
    return jsonify({"status": "healthy", "color": COLOR}), 200

@app.route("/ready")
def ready():
    return jsonify({"status": "ready", "color": COLOR}), 200

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3000, debug=False)
