# Cloudways API Action

Call any [Cloudways API](https://developers.cloudways.com/) endpoint from GitHub Actions, using a Cloudways Access Token.

Use it to deploy with git pull, purge caches, reset file permissions, manage SSH/SFTP IP whitelists, or call any other endpoint, as steps in your workflows.

## Features

- **Any endpoint, any method:** `GET`, `POST`, `PUT`, `DELETE`.
- **Simple request body:** one `key:value` per line. Arrays are written as `ip[]:a,b`.
- **Response values as env variables:** export fields from the response (for example the current IP whitelist) for later steps.
- **Optional waiting:** wait for Cloudways background operations such as git pull to finish.
- **Clear failures:** the step fails on API errors, with hints for an expired token, a missing scope or a wrong path.
- **Lightweight:** a composite action written in bash, `curl` and `jq`. No Docker image, no Node.

## Quick start

```yaml
- name: Clear app cache
  uses: titas-uddin/cloudways-api-action@v1
  with:
    access-token: ${{ secrets.CLOUDWAYS_ACCESS_TOKEN }}
    api-path: /app/cache/purge
    request-body: |
      server_id:${{ secrets.CLOUDWAYS_SERVER_ID }}
      app_id:${{ secrets.CLOUDWAYS_APP_ID }}
```

## Setup

1. **Create an Access Token** in Cloudways: **Profile → API Integration → Access Token Details → Create Access Token**.
   - Choose **Limited Access** and select only the endpoints your workflows call.
   - Set an expiry date.
2. **Add the token to GitHub** as the secret `CLOUDWAYS_ACCESS_TOKEN`. An organization secret shared with selected repositories works well.
3. **Add your server and app IDs** as repository secrets (`CLOUDWAYS_SERVER_ID`, `CLOUDWAYS_APP_ID`).

## Inputs

| Input | Default | Description |
|---|---|---|
| `access-token` | *required* | Cloudways Access Token |
| `api-path` | *required* | Endpoint path, e.g. `/git/pull` |
| `request-method` | `POST` | `GET`, `POST`, `PUT` or `DELETE` |
| `request-body` | `''` | Parameters, one `key:value` per line |
| `request-format` | `json` | Body encoding for non-GET requests: `json` or `form` |
| `request-response` | `''` | Response values to export as env variables, one `path:default` per line |
| `prefix` | `cw_` | Prefix for exported env variable names |
| `api-version` | `v2` | API version |
| `api-base-url` | `https://api.cloudways.com/api` | Base URL without the version |
| `wait-for-operation` | `false` | Wait for a background operation to finish |
| `operation-timeout` | `300` | Maximum seconds to wait |

## Outputs

| Output | Description |
|---|---|
| `response` | Raw JSON response |
| `http-code` | HTTP status code |
| `operation-id` | Operation ID, if the call started a background operation |

## Request body

```yaml
request-body: |
  server_id:123456
  app_id:654321
  branch_name:main
  deploy_path:
  ip[]:1.1.1.1/32,2.2.2.2/32
```

- `GET` sends the parameters as a query string. Other methods send JSON, for example `{"server_id":123456,...,"ip":["1.1.1.1/32","2.2.2.2/32"]}`.
- A key ending in `[]` becomes an array, split on commas. Empty items are dropped.
- Numbers and other valid JSON values are sent as JSON. Everything else is sent as a string.
- Empty lines and lines starting with `#` are ignored.

## Using response values

Each `request-response` line is `path:default`. The value is exported as `<prefix><path>`, with every non-alphanumeric character turned into `_`.

```yaml
- uses: titas-uddin/cloudways-api-action@v1
  with:
    access-token: ${{ secrets.CLOUDWAYS_ACCESS_TOKEN }}
    api-path: /security/whitelisted
    request-method: GET
    request-body: |
      server_id:${{ secrets.CLOUDWAYS_SERVER_ID }}
    request-response: |
      data.ip_list:[]
      data.policy:

- run: echo "IPs: $cw_data_ip_list, policy: $cw_data_policy"
```

- Arrays are exported comma-separated, so they can be passed straight into an `ip[]:` line.
- Objects are exported as JSON.
- A missing path uses the default.

## Background operations

Git pull, reset permissions and cache purge run in the background on Cloudways. The API call returns at once.

- **`wait-for-operation: false`** (default): add a `sleep` step before anything that depends on the result.
- **`wait-for-operation: true`**: the action waits until the operation finishes, and fails the step if it fails. This needs the `GET /operation/{id}` token scope.

## Errors

The step fails on HTTP 400 or above, on a `"status": false` response, or when a waited operation fails.

| HTTP | Likely cause |
|---|---|
| 401 | Token wrong, expired or revoked |
| 403 | The token's scope doesn't include this endpoint |
| 404 / 410 | Wrong `api-path` or `api-version` |

The access token is masked in logs.

## Example: deploy pipeline

This workflow deploys an app on every push to `main`:
1. Whitelists the runner's IP for SSH.
2. Runs git pull and an SSH build step.
3. Puts the whitelist and file ownership back, even if the build fails.
4. Purges the cache.

`POST /security/whitelisted` replaces the whole list, so the workflow reads the current list first and always sends it back. The whitelist applies to the whole server, so adding only the runner's IP is safer than allowing all IPs. Keep these steps in one job, because each job gets a new runner IP.

```yaml
name: Deploy to Cloudways

on:
  push:
    branches: [main]

concurrency:
  group: cloudways-deploy  # secrets can't be used here; this stops two deploys running at once

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Get current SSH/SFTP whitelist
        uses: titas-uddin/cloudways-api-action@v1
        with:
          access-token: ${{ secrets.CLOUDWAYS_ACCESS_TOKEN }}
          api-path: /security/whitelisted
          request-method: GET
          request-body: |
            server_id:${{ secrets.CLOUDWAYS_SERVER_ID }}
          request-response: |
            data.ip_list:[]
            data.policy:

      - name: Get runner IP
        run: echo "RUNNER_IP=$(curl -fsS https://api.ipify.org)" >> "$GITHUB_ENV"

      - name: Whitelist runner IP
        uses: titas-uddin/cloudways-api-action@v1
        with:
          access-token: ${{ secrets.CLOUDWAYS_ACCESS_TOKEN }}
          api-path: /security/whitelisted
          request-body: |
            server_id:${{ secrets.CLOUDWAYS_SERVER_ID }}
            ip[]:${{ env.cw_data_ip_list }},${{ env.RUNNER_IP }}/32
            type:sftp
            ipPolicy:block_all

      - name: Git pull
        uses: titas-uddin/cloudways-api-action@v1
        with:
          access-token: ${{ secrets.CLOUDWAYS_ACCESS_TOKEN }}
          api-path: /git/pull
          request-body: |
            server_id:${{ secrets.CLOUDWAYS_SERVER_ID }}
            app_id:${{ secrets.CLOUDWAYS_APP_ID }}
            branch_name:${{ github.ref_name }}
            deploy_path:

      - name: Wait for git pull
        run: sleep 60

      - name: Ownership to master user
        uses: titas-uddin/cloudways-api-action@v1
        with:
          access-token: ${{ secrets.CLOUDWAYS_ACCESS_TOKEN }}
          api-path: /app/manage/reset_permissions
          request-body: |
            server_id:${{ secrets.CLOUDWAYS_SERVER_ID }}
            app_id:${{ secrets.CLOUDWAYS_APP_ID }}
            ownership:master_user

      - name: Wait for ownership change
        run: sleep 30

      - name: Build on the server
        uses: appleboy/ssh-action@v1.2.0
        with:
          host: ${{ secrets.CLOUDWAYS_SSH_HOST }}
          username: ${{ secrets.CLOUDWAYS_SSH_USER }}
          password: ${{ secrets.CLOUDWAYS_SSH_PASSWORD }}
          script: |
            cd ~/applications/<app-folder>/public_html
            # your build commands, e.g. npm ci && npm run build

      # Cleanup runs even if a step above failed.

      - name: Restore whitelist
        if: always() && env.cw_data_policy != ''
        uses: titas-uddin/cloudways-api-action@v1
        with:
          access-token: ${{ secrets.CLOUDWAYS_ACCESS_TOKEN }}
          api-path: /security/whitelisted
          request-body: |
            server_id:${{ secrets.CLOUDWAYS_SERVER_ID }}
            ip[]:${{ env.cw_data_ip_list }}
            type:sftp
            ipPolicy:${{ env.cw_data_policy }}

      - name: Ownership back to system user
        if: always()
        uses: titas-uddin/cloudways-api-action@v1
        with:
          access-token: ${{ secrets.CLOUDWAYS_ACCESS_TOKEN }}
          api-path: /app/manage/reset_permissions
          request-body: |
            server_id:${{ secrets.CLOUDWAYS_SERVER_ID }}
            app_id:${{ secrets.CLOUDWAYS_APP_ID }}
            ownership:sys_user

      - name: Purge cache
        uses: titas-uddin/cloudways-api-action@v1
        with:
          access-token: ${{ secrets.CLOUDWAYS_ACCESS_TOKEN }}
          api-path: /app/cache/purge
          request-body: |
            server_id:${{ secrets.CLOUDWAYS_SERVER_ID }}
            app_id:${{ secrets.CLOUDWAYS_APP_ID }}
```

This pipeline's token needs these scopes:
- `GET` and `POST /security/whitelisted`
- `POST /git/pull`
- `POST /app/manage/reset_permissions`
- `POST /app/cache/purge`
