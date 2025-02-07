from flask import Flask, request, jsonify

app = Flask(__name__)

def log_request(method, path):
    token = request.headers.get("Authorization")
    if token:
        print(f"Received {method} on {path} with bearer token: {token}")
    else:
        print(f"Received {method} on {path} without bearer token")

# Return a JSON imitating a cookie with a token
@app.route('/api/auth/get-token', methods=['POST'])
def get_token():
    log_request("POST", "/api/auth/get-token")
    # Access form data (for application/x-www-form-urlencoded payloads)
    form_data = request.form

    # Print each form field to the console
    print("Received form data:")
    for key, value in form_data.items():
        print(f"  {key}: {value}")

    # Mocked token response, same as before
    token_data = {
        "name": "session",
        "value": "eyJhb_THIS_IS_A_MOCKED_JWT_TOKEN_CJ9.eyJ1c2VySWQiOiIxMjMiLCJuYW1lIjoiam9obiIsImlhdCI6MTUxNjIzOTAyMn0.GVS21Zrwf-8epIL7jUgnBBd5BxFxr0toB2BYQIxh6IU",
        "domain": "example.com",
        "path": "/"
    }
    return jsonify(token_data)


# GET returns client details including two account endpoints.
# POST echoes back the received JSON body.
@app.route('/api/client/1234-567', methods=['GET', 'POST'])
def client():
    if request.method == "GET":
        log_request("GET", "/api/client/1234-567")
        data = {
            "client_id": "1234-567",
            "firstname": "John",
            "lastname": "Doe",
            "accounts": [
                "333-001",
                "333-002"
            ]
        }
        return jsonify(data)
    else:  # POST
        log_request("POST", "/api/client/1234-567")
        req_data = request.get_json()
        return jsonify({"echo": req_data})

# GET endpoints for two accounts.
# PUT echoes back the received JSON body.
@app.route('/api/client/1234-567/<account>', methods=['GET', 'PUT'])
def account(account):
    if request.method == "GET":
        log_request("GET", f"/api/client/1234-567/{account}")
        data = {
            "client_id": "1234-567",
            "account": account,
            "balance": 1000  # an arbitrary value
        }
        return jsonify(data)
    else:  # PUT
        log_request("PUT", f"/api/client/1234-567/{account}")
        req_data = request.get_json()
        return jsonify({"echo": req_data})

if __name__ == '__main__':
    # Listen on all interfaces (inside container) at port 5000.
    app.run(host='0.0.0.0', port=5000)