# ceph-raz

Local Ceph RADOS Gateway (RGW) with automated IAM provisioning for S3 and STS testing (e.g. Apache Ranger Raz).

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) and Docker Compose
- On Apple Silicon Macs, the stack runs via `linux/amd64` emulation (configured in `docker-compose.yml`)

## Quick start

```bash
docker compose up -d
```

Two services start:

| Service | Description |
|---------|-------------|
| `ceph-demo-auto` | Ceph demo cluster with RGW (Beast frontend) |
| `ceph-auto-provisioner` | Runs `init-ceph.sh` once the cluster is healthy |

Watch provisioning until it completes. **All credentials and connection details you need** (access keys, role ARN, endpoint, bucket name, etc.) are printed at the end of the run:

```bash
docker compose logs -f ceph-auto-provisioner
```

Look for the `PROVISIONING SUMMARY` block at the bottom of the output.

## Ports

| Host port | Service | Purpose |
|-----------|---------|---------|
| `8081` | RGW (S3 API) | S3/STS endpoint from your host |

## Stop and clean up

```bash
docker compose down -v --remove-orphans 
```

## Project layout

```
.
├── docker-compose.yml   # Ceph demo + auto-provisioner services
├── init-ceph.sh         # RGW, IAM, and S3 setup script
└── README.md
```

## Notes

- This setup is for **local development and testing only**.
- RGW listens on `8080` inside the container; the host maps it to `8081` to avoid common port conflicts.