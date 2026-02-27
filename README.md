# gitea-deployer
Fast as Fuck Gitea deployment and act_runner with Docker Compose.

# First run

```bash
docker network create gitea
cp .env.example .env
```

# Run Gitea

```bash
docker compose up -d
```

# Logs

```bash
docker compose logs -f
```

# Poweroff Gitea

```bash
docker compose down
```

# Panic purge all shits
Warning: This will remove all containers. Use with caution.

```bash
rm -rf gitea postgres runner shared
docker system prune -a -f
```
