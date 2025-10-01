# MinIO + Keycloak OIDC Integration

🔐 **Seamless authentication between MinIO and Keycloak using OIDC and AWS STS**

## 🎯 Overview

This solution provides programmatic authentication to MinIO using Keycloak as an OIDC Identity Provider. It bypasses the deprecated MinIO Console OIDC login by directly exchanging Keycloak JWT tokens for temporary AWS credentials via MinIO's STS (Security Token Service).

### 🚀 Why This Solution?

- **MinIO Community Edition** removed OIDC console login in recent versions
- **Enterprise features** like OIDC web login require MinIO Enterprise
- **This solution** recreates OIDC authentication programmatically using standard APIs
- **AWS-compatible** credentials work with all S3 SDKs and tools

## 🏗️ Architecture

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Script    │───▶│  Keycloak   │───▶│  MinIO STS  │───▶│ AWS Creds   │
│             │    │   (OIDC)    │    │    (API)    │    │ (Temporary) │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
     Direct              JWT              Exchange           1h validity
   Authentication      with claims      AssumeRoleWith      AccessKey +
                      (groups/policy)   WebIdentity         SecretKey +
                                                           SessionToken
```

### 🔄 Flow Details

1. **Direct Authentication**: Script authenticates directly with Keycloak (no browser redirect)
2. **JWT Token**: Keycloak returns JWT with user claims (groups, policy)
3. **STS Exchange**: MinIO validates JWT and returns temporary AWS credentials
4. **AWS Compatibility**: Use credentials with any AWS S3 client/SDK

## 🛠️ Prerequisites

### Required Tools
- `curl` - HTTP client
- `jq` - JSON processor
- `xmllint` (optional) - XML processor (sed fallback available)
- `aws` CLI (optional) - For testing S3 access

### MinIO Configuration
MinIO must be configured with OIDC Identity Provider:

```yaml
# MinIO Helm values
oidc:
  enabled: true
  configUrl: "https://your-keycloak.example.com/auth/realms/your-realm/.well-known/openid-configuration"
  clientId: "minio-client"
  existingClientSecretName: "minio-oidc-secret"
  existingClientSecretKey: "client-secret"
  claimName: "policy"  # Keycloak claim containing MinIO policy names
  scopes: "openid,profile,email,groups"
  comment: "OIDC Authentication for MinIO"
```

### Keycloak Configuration
1. **Client Setup**: Create OIDC client with `Direct Access Grants` enabled
2. **Mappers**: Configure group membership mapper to include groups in `policy` claim
3. **Groups**: Create groups matching MinIO policy names

## 📋 Installation

### 1. Clone or Download
```bash
git clone <this-repo>
cd minio-keycloak-oidc-integration
```

### 2. Configure Environment
```bash
export KEYCLOAK_URL="https://your-keycloak.example.com/auth/realms/your-realm/protocol/openid-connect/token"
export CLIENT_ID="your-minio-client-id"
export MINIO_STS_URL="https://minio-api.example.com"
```

### 3. Run Authentication Script
```bash
# Interactive mode
./scripts/login-minio-oidc.sh

# With username
./scripts/login-minio-oidc.sh john.doe

# With environment variables (secure)
KEYCLOAK_PASSWORD=xxx KEYCLOAK_CLIENT_SECRET=yyy ./scripts/login-minio-oidc.sh john.doe
```

## 🔧 Usage Examples

### Basic Usage
```bash
$ ./scripts/login-minio-oidc.sh john.doe
Password: [hidden]
Client Secret: [hidden]
🔑 Getting Keycloak token for john.doe...
✅ Successfully obtained Keycloak token
📜 JWT payload (relevant claims):
{
  "preferred_username": "john.doe",
  "policy": ["CloudDevOps", "DataAccess"],
  "groups": ["/CloudDevOps", "/DataAccess"],
  "exp": 1704067200
}
🔄 Exchanging token with MinIO STS...
✅ Successfully obtained temporary AWS credentials (valid 1 hour)
🔗 AWS credentials configured. Testing access...
2024-01-01 12:00:00 bucket1
2024-01-01 12:00:00 bucket2
🎉 Authentication complete!
```

### Using with AWS CLI
```bash
# After running the script, credentials are exported
aws --endpoint-url https://minio-api.example.com s3 ls
aws --endpoint-url https://minio-api.example.com s3 cp file.txt s3://bucket1/
```

### Using with Python boto3
```python
import boto3

# Credentials are automatically picked up from environment
s3 = boto3.client('s3', endpoint_url='https://minio-api.example.com')
response = s3.list_buckets()
print(response['Buckets'])
```

## 📁 Repository Structure

```
minio-keycloak-oidc-integration/
├── README.md                    # This file
├── scripts/
│   └── login-minio-oidc.sh     # Main authentication script
├── helm/
│   ├── values-example.yaml     # MinIO Helm configuration example
│   └── external-secrets.yaml   # External Secrets template
├── keycloak/
│   └── client-config.json      # Keycloak client configuration example
├── docs/
│   ├── ARCHITECTURE.md         # Technical deep-dive
│   ├── TROUBLESHOOTING.md      # Common issues and solutions
│   └── KEYCLOAK_SETUP.md       # Keycloak configuration guide
└── LICENSE                     # MIT License
```

## 🔒 Security Considerations

### ✅ Secure Practices
- **No hardcoded secrets** in scripts
- **Environment variables** for sensitive data
- **Masked password input** (`read -s`)
- **Temporary credentials** (1-hour expiry)
- **JWT validation** by MinIO

### ⚠️ Important Notes
- Client secrets should be stored securely (e.g., secret management systems)
- JWT tokens have short lifespans - re-authenticate as needed
- Always use HTTPS for all endpoints
- Regularly rotate client secrets

## 🐛 Troubleshooting

### Common Issues

#### "Failed to get access token from Keycloak"
- Verify Keycloak URL and credentials
- Check client configuration (Direct Access Grants enabled)
- Ensure client secret is correct

#### "Failed to extract credentials from STS response"
- Verify MinIO OIDC configuration
- Check JWT claims match MinIO policies
- Ensure MinIO can reach Keycloak for token validation

#### "None of the given policies are defined"
- JWT `policy` claim must match existing MinIO policy names
- Configure Keycloak group mapper correctly
- Create corresponding policies in MinIO

See [TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) for detailed solutions.

## 🤝 Contributing

Contributions are welcome! Please:

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests if applicable
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- MinIO team for the excellent S3-compatible storage
- Keycloak community for the robust OIDC implementation
- AWS for the STS API specification

## 📚 Related Resources

- [MinIO Documentation](https://docs.min.io/)
- [Keycloak Documentation](https://www.keycloak.org/documentation)
- [AWS STS AssumeRoleWithWebIdentity](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRoleWithWebIdentity.html)
- [OIDC Specification](https://openid.net/connect/)

---

**⭐ If this solution helped you, please give it a star!**
