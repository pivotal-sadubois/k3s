# Create Employee:
curl -X POST -H "Content-Type: application/json" \
-d '{"firstName":"Alice","lastName":"Smith","email":"alice@example.com"}' \
http://localhost:8080/api/employees

# Update Employee:
curl -X PUT -H "Content-Type: application/json" \
-d '{"firstName":"Alice","lastName":"Johnson","email":"alice.j@example.com"}' \
http://localhost:8080/api/employees/1

# curl -X GET -H "Content-Type: application/json" http://localhost:8080/api/employees 2>/dev/null | jq -r

# Delete a User
curl -X DELETE -H "Content-Type: application/json" http://localhost:8080/api/employees/1

# Get all Employees
curl -X GET -H "Content-Type: application/json" https://edb.apps.corelab.core-software.ch/api/employees 2> /dev/null | jq -r
curl -X GET -H "Content-Type: application/json" https://edb.apps.fortidemo.ch/api/employees 2> /dev/null | jq -r

# Get a single Employees
curl -X GET -H "Content-Type: application/json" https://edb.apps.corelab.core-software.ch/api/employees/1 2> /dev/null | jq -r
curl -X GET -H "Content-Type: application/json" https://edb.apps.Fortidemo.ch/api/employees/1 2> /dev/null | jq -r


# Bad requests
curl -X GET -H "Content-Type: application/json" https://edb.apps.corelab.core-software.ch/api/employees/xxx 2> /dev/null | jq -r
curl -X GET -H "Content-Type: application/json" https://edb.apps.Fortidemo.ch/api/employees/xxx 2> /dev/null | jq -r
curl -X GET -H "Content-Type: text/plain" https://edb.apps.Fortidemo.ch/api/employees/1 2> /dev/null | jq -r
curl -X GET -H "Content-Type: text/plain" https://edb.apps.corelab.core-software.ch/api/employees/xxx 2> /dev/null | jq -r

text/plain
