# REST-Call Sequencing Tool Requirements

This document describes the complete set of requirements for a Perl-based script that executes a series of REST calls as specified in a configuration file, logs requests and responses, handles parameter extractions and obfuscations, and supports additional HTTP headers. It also includes an example configuration file and references to the script implementation.

## 1. Introduction

We need a tool that automates a sequence of REST calls. It must fetch a bearer token (optional), substitute variables (across URLs, bodies, and commands), execute each call, extract parameters from responses, optionally obfuscate sensitive data, and log everything thoroughly. This tool is intended to be run in an Ubuntu container with standard UNIX utilities (`curl`, `jq`, `sed`, `grep`, `awk`) plus `perl`.

## 2. Features and Capabilities

1. **Container Environment**  
   - The script runs inside an Ubuntu container (recent version).
   - Assumes tools like `curl`, `jq`, `sed`, `grep`, and `awk` are available.

2. **Implementation**  
   - Script is written in Perl.
   - Delegates REST calls to `curl`.

3. **Parameters**  
   - **Mandatory**:  
     1. **Configuration file** (JSON) describing the sequence of REST calls.  
     2. **Workdir** path or `__timestamp` (which creates `work_<ISO8601>`).  
   - **Optional**:  
     1. `--dry-run` (default: off).  
     2. `--continue-on-error=(yes|no)` (default: yes).  
     3. `--call-delay=X` (default: X = 100; 0..60000).  

4. **Configuration File Format**  
   - **Token Fetch** (optional):  
     - A `token_fetch_url` that is fetched with GET to retrieve JSON.  
     - A `token_extraction_command` for extracting the bearer token (e.g., `jq -r .access_token`).  
     - The token fetch URL may contain environment variable placeholders such as `${SECRET}`. These placeholders **must not be expanded** by the script itself; `curl` shall see them unexpanded.  
   - **Variables** (optional):  
     - A map (key → value) for simple text substitutions in subsequent calls (URL, body, parameter extraction commands, obfuscation commands).  
   - **Base URL**:  
     - A common prefix to be applied to each call’s relative URL snippet.  
   - **Sequence of Calls**:  
     - Each call has:  
       - `identifier` (alphanumeric plus `_` or `-`),  
       - `rest_method` (`GET`, `POST`, or `PUT`),  
       - `url` (appended to `base_url` after variable replacement),  
       - optional `body_file` referencing either an absolute/relative path or a `W:` prefix indicating a file in the workdir,  
       - optional list of `param_extractions` (commands reading response from stdin, writing extracted value to stdout),  
       - optional list of `obfuscation_rules` (commands that read from stdin, transform, write to stdout, applied sequentially),  
       - **optional** list of `headers` to be passed to `curl` as additional HTTP headers.  
     - For each call, we apply variable replacements in the URL snippet, request body, header lines, and subsequent parameter extraction / obfuscation commands.  
   - **Escaped Double Quotes**:  
     - If the config file contains escaped double quotes, `decode_json` in Perl can typically handle them as long as the JSON is well-formed.

5. **Workdir Handling**  
   - If the named workdir already exists, the script aborts. Otherwise, it creates the directory.  
   - If the workdir is `__timestamp`, the script derives a name `work_<timestamp>` in ISO8601 format.  

6. **Dry-run Mode**  
   - If `--dry-run` is active, no actual network calls occur. Instead, HTTP status is simulated as `999`, which is treated as success.  
   - The script still performs variable substitutions and logs the *intended* `curl` commands so users can see what *would* have happened.

7. **Continue on Error**  
   - If set to `no`, the script stops upon the first call failure (non-2xx, except 999).  
   - If set to `yes`, the script continues executing subsequent calls.

8. **Bearer Token Workflow**  
   - (Optional) If `token_fetch_url` is in the config, the script performs a GET call to retrieve a JSON structure from which the bearer token is extracted using a user-defined command (`token_extraction_command`).  
   - If dry-run is **off** and the token fetch fails, the script aborts.  
   - If dry-run is **on**, the script returns `"DRYRUN_BEARER_TOKEN"` as a dummy token.  
   - The script logs the entire `curl` command for token fetch to a global log file but does not expand environment placeholders.  

9. **Execution of Calls**  
   - For each configured call:  
     1. **Resolve** the final URL by concatenating `base_url` + call’s `url` snippet + variable replacements.  
     2. **Load** and apply variable replacements to the request body, if any, then save it as `x_<identifier>_request.json`.  
     3. **Assemble** the `curl` command with the method, the final URL, the request body (if present), the authorization header (with token if any), and any extra headers declared in the config.  
     4. **Log** the fully composed `curl` command to `all_curl_calls.txt` (still unexpanded environment variables in the URL or headers).  
     5. **If** not in dry-run mode, actually run the call. Otherwise, simulate.  
     6. **Write** response to `x_<identifier>_response.json` (on success) or omit if the call fails.  
     7. **Record** a summary in `l_<identifier>_<http_status>.txt` (variables before, request body, URL, status code, response body, and variables after any extraction).  
     8. **Apply** `param_extractions` in order, piping the response body to each extraction command and updating variables accordingly.  
     9. **Obfuscations**: If the call was successful, read from `x_*.json` (request and response) to produce obfuscated `p_*.json` files. Each rule is applied in sequence.  

10. **Logging**  
   - **Global**: `all_curl_calls.txt` enumerates all derived `curl` commands, one per line plus a blank line.  
   - **Private** files: `x_<identifier>_request.json`, `x_<identifier>_response.json` store the raw request/response (if successful).  
   - **Public** (obfuscated) files: `p_<identifier>_request.json`, `p_<identifier>_response.json` after applying the obfuscation pipeline.  
   - **Detailed** log per call: `l_<identifier>_<http_status>.txt`.

11. **Security Considerations**  
   - The script never internally expands environment variable placeholders (`\${NAME}`) in URLs or headers. That happens externally by the shell or remains unresolved if absent in the environment.  
   - The bearer token is not considered secret for logging purposes here, but environment variables (like credentials) remain unexpanded in logged commands.  
   - Obfuscation steps can remove or mask sensitive data from the final logs.  

12. **Chained Calls**  
   - This tool can handle complex workflows by extracting parameters from one call’s response and substituting them into subsequent calls, enabling advanced multi-step operations.

## 3. Usage

1. **Install** or place the Perl script in a suitable location.  
2. **Provide** a valid JSON config describing the sequence of calls.  
3. **Set** any environment variables needed by your placeholders (e.g., `ENV_TOKEN_ENDPOINT`, `ENV_API_VERSION`).  
4. **Invoke** the script with:  

<pre><code>```
# First, define any environment variables:
export ENV_TOKEN_ENDPOINT="v1/getToken"
export ENV_API_VERSION="prod"
export ENV_SPECIAL_HEADER="some-secret"

# Then run the script:
perl rest_sequence_script.pl --dry-run --call-delay=120 config_example.json __timestamp

``` </code></pre>

   - `--dry-run` to simulate.  
   - `--continue-on-error=no` to stop on first failure.  
   - `--call-delay=120` inserts a sleep of 120 millis before each rest call.     
   - The two mandatory arguments: `config-file` and `workdir` (or `__timestamp`).  

## 4. Example Configuration

Below is a reference for a sample JSON config. It demonstrates:

- A token fetch with an environment placeholder in the URL.  
- A `token_extraction_command` that uses `jq`.  
- Replacement variables.  
- Two calls with varying methods, param extraction, obfuscation, and additional headers.  

<pre><code>```json 
{
    "token_fetch_url": "https://auth.example.com/${ENV_TOKEN_ENDPOINT}",
    "token_extraction_command": "jq -r .access_token",
    "variables": {
      "CALL_VAR_USER_ID": "user123"
    },
    "base_url": "https://api.example.com/${ENV_API_VERSION}/v1",
    "calls": [
      {
        "identifier": "CALL1",
        "rest_method": "GET",
        "url": "/users/${CALL_VAR_USER_ID}/profile",
        "headers": [],
        "comment": "Fetch the user's profile (no extra headers)",
        "param_extractions": [
          {
            "var_name": "CALL_VAR_PROFILE_ID",
            "cmd": "jq -r .profileId | sed 's/^/PROFILE_/'"
          }
        ],
        "obfuscation_rules": [
          {
            "cmd": "sed 's/\"phoneNumber\": \".*\"/\"phoneNumber\": \"[HIDDEN]\"/'"
          }
        ]
      },
      {
        "identifier": "CALL2",
        "rest_method": "POST",
        "url": "/profiles/${CALL_VAR_PROFILE_ID}/photos",
        "headers": [
          "X-Special-Header: MyHeaderValue",
          "X-Another-Header: ${ENV_SPECIAL_HEADER}"
        ],
        "comment": "Upload a user photo with additional headers",
        "body_file": "W:user_photo.json",
        "param_extractions": [
          {
            "var_name": "CALL_VAR_NEW_PHOTO_ID",
            "cmd": "jq -r .photoId"
          }
        ],
        "obfuscation_rules": [
          {
            "cmd": "sed 's/123/ABC/g'"
          }
        ]
      }
    ]
  }
   ``` </code></pre>


## 5. Conclusion

By following these instructions and configuration guidelines, users can automate complex, multi-step REST interactions, log the complete process (both private and obfuscated data), and optionally continue or stop on error. The script’s dry-run mode helps stakeholders review the exact `curl` calls without hitting live endpoints, providing confidence in each step of the process.

