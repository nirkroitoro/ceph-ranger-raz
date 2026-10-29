#!/bin/bash
set -e

HOSTNAME=$(docker exec ceph-demo-auto hostname)

restart_rgw() {
  echo "Gracefully stopping any existing radosgw process..."
  docker exec ceph-demo-auto pkill -15 -f radosgw || true
  sleep 2

  echo "Launching radosgw daemon explicitly with Beast on 0.0.0.0:8080..."
  docker exec ceph-demo-auto sh -c "nohup radosgw \
    -n client.rgw.${HOSTNAME} \
    -k /var/lib/ceph/radosgw/ceph-rgw.${HOSTNAME}/keyring \
    --rgw-frontends='beast endpoint=0.0.0.0:8080' \
    --default-log-to-stderr=true </dev/null >/var/log/ceph/rgw.log 2>&1 &"

  echo "Waiting for RGW to answer on port 8080..."
  until docker exec ceph-demo-auto curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/ | grep -E "200|403"; do
    sleep 2
  done
  echo "RGW is healthy and responsive on port 8080."
}

echo "=== [1/6] Waiting for Ceph cluster quorum... ==="
until docker exec ceph-demo-auto ceph health; do
  sleep 2
done
echo "Ceph cluster is up."

# 1. Inject STS and Beast configuration directly into ceph.conf AND central store
docker exec ceph-demo-auto bash -c '
sed -i "/^rgw frontends/d" /etc/ceph/ceph.conf
sed -i "/^rgw s3 auth use sts/d" /etc/ceph/ceph.conf
sed -i "/^rgw sts key/d" /etc/ceph/ceph.conf
sed -i "/^rgw dns name/d" /etc/ceph/ceph.conf
sed -i "/^rgw resolve cname/d" /etc/ceph/ceph.conf

cat << "EOF" >> /etc/ceph/ceph.conf
rgw frontends = beast endpoint=0.0.0.0:8080
rgw s3 auth use sts = true
rgw sts key = 0123456789abcdef0123456789abcdef
rgw dns name = localhost,127.0.0.1,ceph-demo-auto
rgw resolve cname = false
EOF
'

docker exec ceph-demo-auto ceph config set client.radosgw rgw_frontends "beast endpoint=0.0.0.0:8080"
docker exec ceph-demo-auto ceph config set client.radosgw rgw_dns_name "localhost,127.0.0.1,ceph-demo-auto"
docker exec ceph-demo-auto ceph config set client.radosgw rgw_resolve_cname false
docker exec ceph-demo-auto ceph config set client.radosgw rgw_sts_key "0123456789abcdef0123456789abcdef"
docker exec ceph-demo-auto ceph config set client.radosgw rgw_s3_auth_use_sts true

# Initial launch of RGW
restart_rgw

echo "=== [2/6] Configuring zonegroup us-east-1 and hostnames compatibility... ==="
docker exec ceph-demo-auto radosgw-admin zonegroup get > /tmp/zg.json

# Hostnames mapping includes both internal 8080 and host-forwarded 8081
jq '.api_name = "us-east-1" |
    .hostnames = ["localhost", "127.0.0.1", "ceph-demo-auto", "localhost:8081", "127.0.0.1:8081", "localhost:8080", "127.0.0.1:8080", "ceph-demo-auto:8080"] |
    .endpoints = ["http://127.0.0.1:8080", "http://ceph-demo-auto:8080"] |
    .zones[0].endpoints = ["http://127.0.0.1:8080", "http://ceph-demo-auto:8080"]' /tmp/zg.json > /tmp/zg_updated.json

docker exec -i ceph-demo-auto radosgw-admin zonegroup set < /tmp/zg_updated.json

# Restart RGW so it picks up the zonegroup endpoints and hostnames
restart_rgw

echo "=== [3/6] Setting up IAM Account and Root Admin User... ==="
docker exec ceph-demo-auto radosgw-admin account create --account-name=ranger-account
ACCOUNT_ID=$(docker exec ceph-demo-auto radosgw-admin account get --account-name=ranger-account | grep '"id"' | head -1 | cut -d '"' -f 4)

# Create the account root user
docker exec ceph-demo-auto radosgw-admin user create \
  --uid=s3root \
  --display-name="S3Root" \
  --account-id="${ACCOUNT_ID}" \
  --account-root \
  --system \
  --access-key=root_access \
  --secret-key=root_secret

# Add administrative caps so s3root has full IAM API permissions
docker exec ceph-demo-auto radosgw-admin caps add --uid=s3root --caps="users=*;roles=*;buckets=*;user-policy=*"

echo "Configured Account ID: ${ACCOUNT_ID}"

echo "=== [4/6] Creating IAM User, Access Keys, and User Policy via AWS CLI IAM... ==="
mkdir -p /root/.aws
cat << 'AWS_CONFIG' > /root/.aws/config
[default]
region = us-east-1
s3 =
    addressing_style = path
    signature_version = s3v4
AWS_CONFIG

cat << 'AWS_CREDS' > /root/.aws/credentials
[default]
aws_access_key_id = root_access
aws_secret_access_key = root_secret
AWS_CREDS

export AWS_DEFAULT_REGION="us-east-1"
ENDPOINT="http://ceph-demo-auto:8080"
RANGER_USER="ranger-user"

# 1. Create IAM User using AWS CLI
echo "Creating IAM user ${RANGER_USER} via AWS CLI..."
aws --endpoint-url "${ENDPOINT}" --region us-east-1 iam create-user \
  --user-name "${RANGER_USER}"

# 2. Generate Access Key using AWS CLI
echo "Generating Access Key for ${RANGER_USER} via AWS CLI..."
KEY_JSON=$(aws --endpoint-url "${ENDPOINT}" --region us-east-1 iam create-access-key \
  --user-name "${RANGER_USER}")

RANGER_KEY=$(echo "${KEY_JSON}" | jq -r '.AccessKey.AccessKeyId')
RANGER_SECRET=$(echo "${KEY_JSON}" | jq -r '.AccessKey.SecretAccessKey')

# 3. Attach User Policy using AWS CLI
cat << 'USER_POLICY' > /tmp/user-s3-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket",
        "s3:ListAllMyBuckets",
        "s3:ListBucket",
        "s3:*"
      ],
      "Resource": "*"
    }
  ]
}
USER_POLICY

echo "Attaching S3 permissions to user ${RANGER_USER} via AWS CLI..."
aws --endpoint-url "${ENDPOINT}" --region us-east-1 iam put-user-policy \
  --user-name "${RANGER_USER}" \
  --policy-name RangerUserS3Policy \
  --policy-document file:///tmp/user-s3-policy.json

echo "=== [5/6] Creating IAM Role and Role Policy via AWS CLI IAM... ==="
cat << POLICY > /tmp/trust-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::${ACCOUNT_ID}:user/${RANGER_USER}"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
POLICY

cat << 'POLICY' > /tmp/role-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AccessToBucketObjects",
      "Effect": "Allow",
      "Action": [
        "s3:AbortMultipartUpload",
        "s3:DeleteObject",
        "s3:DeleteObjectVersion",
        "s3:GetObject",
        "s3:GetObjectAcl",
        "s3:GetObjectVersion",
        "s3:GetObjectVersionAcl",
        "s3:PutObject",
        "s3:ListMultipartUploadParts"
      ],
      "Resource": "arn:aws:s3:::ranger-test-bucket/*"
    },
    {
      "Sid": "AccessToBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketAcl",
        "s3:GetBucketLocation",
        "s3:GetBucketVersioning",
        "s3:ListBucket",
        "s3:ListBucketMultipartUploads"
      ],
      "Resource": "arn:aws:s3:::ranger-test-bucket"
    }
  ]
}
POLICY

# 1. Create Role via AWS CLI IAM
echo "Creating IAM role ranger-s3-role via AWS CLI..."
aws --endpoint-url "${ENDPOINT}" --region us-east-1 iam create-role \
  --role-name ranger-s3-role \
  --assume-role-policy-document file:///tmp/trust-policy.json

# 2. Attach Role Policy via AWS CLI IAM
echo "Attaching role policy to ranger-s3-role via AWS CLI..."
aws --endpoint-url "${ENDPOINT}" --region us-east-1 iam put-role-policy \
  --role-name ranger-s3-role \
  --policy-name S3BucketAccessPolicy \
  --policy-document file:///tmp/role-policy.json

echo "=== [6/6] Creating S3 Bucket using ranger-user credentials... ==="
echo "Creating bucket ranger-test-bucket using ${RANGER_USER} credentials..."

export AWS_ACCESS_KEY_ID="${RANGER_KEY}"
export AWS_SECRET_ACCESS_KEY="${RANGER_SECRET}"

aws --endpoint-url "${ENDPOINT}" --region us-east-1 s3api create-bucket --bucket ranger-test-bucket
aws --endpoint-url "${ENDPOINT}" --region us-east-1 s3api put-object --bucket ranger-test-bucket --key storage/

cat << CRED_EOF > /shared/credentials.env
ACCOUNT_ID=${ACCOUNT_ID}
ROLE_ARN=arn:aws:iam::${ACCOUNT_ID}:role/ranger-s3-role
USER_NAME=${RANGER_USER}
USER_ARN=arn:aws:iam::${ACCOUNT_ID}:user/${RANGER_USER}
ROOT_ACCESS_KEY=root_access
ROOT_SECRET_KEY=root_secret
RANGER_USER_NAME=${RANGER_USER}
RANGER_USER_ACCESS_KEY=${RANGER_KEY}
RANGER_USER_SECRET_KEY=${RANGER_SECRET}
S3_ENDPOINT=http://127.0.0.1:8081
CRED_EOF

echo "--------------------------------------------------------"
echo "PROVISIONING SUMMARY:"
echo "User Name  : ${RANGER_USER}"
echo "Access Key : ${RANGER_KEY}"
echo "Secret Key : ${RANGER_SECRET}"
echo "Role ARN   : arn:aws:iam::${ACCOUNT_ID}:role/ranger-s3-role"
echo "User ARN   : arn:aws:iam::${ACCOUNT_ID}:user/${RANGER_USER}"
echo "Endpoint   : http://127.0.0.1:8081"
echo "Bucket     : ranger-test-bucket"
echo "--------------------------------------------------------"