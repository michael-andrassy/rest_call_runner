## This is a test-setup for the rest_call_runner.pl

- It fires up two containers in docker compose
  - `service`: a mock service which exposes some REST endpoints for testing
    - `app.py` contains the implementation of the mock service and its REST endpoints
  - `runner`: a container in which the `rest_call_runner.pl` will be executed
- It runs the suite of calls configured in `rest_call_sequence_01.json`
- There are two preserved workdirs from earlier runs containing log files and response files 

