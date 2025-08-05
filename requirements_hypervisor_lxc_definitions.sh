# LXC Tools Requirements for Phoenix Server

## Summary
This document outlines the LXC-based tools and environments deployed on the Phoenix Proxmox server to support personal development workflows and dedicated production, testing, and development environments, separate from the `thinkheads.ai` project's Docker-based environments. Tools facilitate coding, automation, monitoring, AI model integration, and GPU management, while `DrProd` serves as the primary production environment, with `DrTest` and `DrDev` cloned from it for testing and development. All run in LXC containers for lightweight resource usage and isolation, leveraging Proxmox’s ZFS storage and GPU passthrough.

## Definition of "Tools"
"Tools" are applications or services used to enhance personal productivity, development, or system management on the Phoenix server. They are not part of `thinkheads.ai`’s core architecture but support tasks like:
- Code development and debugging (e.g., AI model integration with VS Code).
- Workflow automation across environments.
- System monitoring and resource management.
- Local web hosting for personal projects or dashboards.
- Data storage for non-production purposes.
- GPU monitoring and management for development tasks.
The `DrProd` container is the primary production environment for deploying features using Docker Compose, with `DrTest` and `DrDev` cloned from `DrProd` for testing and development consistency.

## List of Tools and Descriptions

1. **NGINX**
   - **Description**: A high-performance web server and reverse proxy for routing traffic to other LXC-based tools (e.g., n8n, Grafana, vLLM, DrProd) and the Proxmox UI. Supports external access with SSL via Let’s Encrypt and Cloudflare integration.
   - **Purpose**: Provides secure, centralized access to tools and Proxmox, both locally and externally.

2. **PostgreSQL**
   - **Description**: A robust relational database for storing data related to personal projects, n8n workflows, and monitoring tools.
   - **Purpose**: Manages structured data for non-`thinkheads.ai` applications, isolated from project databases.

3. **Monitoring (Prometheus/Grafana)**
   - **Description**: Prometheus collects metrics from Proxmox, LXC, and Docker containers, while Grafana visualizes them in dashboards.
   - **Purpose**: Tracks resource usage (e.g., CPU, GPU, memory) to optimize server performance.

4. **n8n**
   - **Description**: A workflow automation tool for orchestrating tasks across LXC and Docker environments (e.g., backups, container management, AI workflows).
   - **Purpose**: Automates repetitive tasks and integrates with PostgreSQL, Redis, and Docker.

5. **Redis**
   - **Description**: An in-memory data store for caching and queuing, supporting n8n workflows and NGINX performance.
   - **Purpose**: Enhances tool performance with fast data access and queue management.

6. **Portainer**
   - **Description**: A web-based GUI for managing Docker containers across LXC (including DrProd, DrTest, DrDev) and `thinkheads.ai` environments, using Docker Compose for deployments.
   - **Purpose**: Simplifies Docker management and ensures consistent container setups.

7. **vLLM (devstral-small)**
   - **Description**: A vLLM instance running the `devstral-small` model, integrated with Cline in VS Code for code assistance.
   - **Purpose**: Provides AI-powered coding support for development tasks.

8. **vLLM (Cline Planning Mode)**
   - **Description**: A vLLM instance running a model optimized for Cline’s planning mode in VS Code, supporting project planning and task organization.
   - **Purpose**: Enhances productivity with AI-driven planning capabilities.

9. **DrProd**
   - **Description**: The primary LXC container with both RTX 5060Ti GPUs passed through, running NVIDIA drivers, container toolkit, and a Docker container with `nvtop` for GPU monitoring. Serves as the production environment for deploying features on the Phoenix server using Docker Compose.
   - **Purpose**: Hosts production-ready applications and services with GPU acceleration, isolated from `thinkheads.ai`.

10. **DrTest**
    - **Description**: An LXC container cloned from `DrProd`, with both RTX 5060Ti GPUs passed through, running NVIDIA drivers, container toolkit, and a Docker container with `nvtop` for GPU monitoring. Serves as the testing environment for validating features before production.
    - **Purpose**: Tests applications and services with GPU acceleration, separate from `thinkheads.ai`.

11. **DrDev**
    - **Description**: An LXC container cloned from `DrProd`, with both RTX 5060Ti GPUs passed through, running NVIDIA drivers, container toolkit, and a Docker container with `nvtop` for GPU monitoring. Serves as the development environment for building and experimenting with features.
    - **Purpose**: Facilitates development and experimentation with GPU resources, outside `thinkheads.ai`.

## Requirements for Each LXC Setup

### 1. NGINX
- **OS**: Debian 12
- **Resources**: 1 CPU core, 2GB RAM, 10GB storage
- **Network**: Static IP, bridged network for access from other LXC containers and external clients
- **Packages**:
  - NGINX (`nginx`)
  - Certbot (`certbot`, `python3-certbot-nginx`) for Let’s Encrypt
  - Optional: `cloudflared` for Cloudflare Tunnel
- **Storage**: ZFS dataset `/quickOS/nginx_config` mounted at `/etc/nginx`
- **Configuration**:
  - Reverse proxy for Proxmox (`https://<proxmox_ip>:8006`), n8n (`/n8n`), Grafana (`/grafana`), vLLM instances (`/vllm`, `/vllm-plan`), DrProd (`/drprod-nvtop`), DrTest (`/drtest-nvtop`), DrDev (`/drdev-nvtop`)
  - SSL certificates via Let’s Encrypt for `proxmox.phoenix.yourdomain.com`, `tools.phoenix.yourdomain.com`
  - HTTP basic authentication for sensitive endpoints
- **Dependencies**: Cloudflare DNS setup, public IP, router port forwarding (80, 443)

### 2. PostgreSQL
- **OS**: Debian 12
- **Resources**: 2 CPU cores, 4GB RAM, 50GB storage
- **Network**: Static IP, bridged network for connections from n8n, monitoring, and other tools
- **Packages**:
  - PostgreSQL (`postgresql`, `postgresql-contrib`)
- **Storage**: ZFS dataset `/quickOS/personal_db` mounted at `/var/lib/postgresql`
- **Configuration**:
  - Database: `personal_db`, User: `personal_user`, Password: secure
  - Allow connections from LXC network range (e.g., `192.168.1.0/24`)
- **Dependencies**: None

### 3. Monitoring (Prometheus/Grafana)
- **OS**: Debian 12
- **Resources**: 2 CPU cores, 4GB RAM, 20GB storage
- **Network**: Static IP, bridged network for metrics collection and dashboard access
- **Packages**:
  - Docker (`docker.io`, `docker-compose`)
  - Prometheus (`prom/prometheus:latest` Docker image)
  - Grafana (`grafana/grafana:latest` Docker image)
  - Node Exporter (`prometheus-node-exporter`) on Proxmox host and LXC containers
- **Storage**: ZFS dataset `/quickOS/monitoring_data` mounted at `/var/lib/docker`
- **Configuration**:
  - Prometheus: Scrape metrics from Proxmox, LXC containers (including DrProd, DrTest, DrDev), and Docker containers
  - Grafana: Dashboards for CPU, GPU, memory, and storage
  - Accessible via NGINX at `/grafana`
- **Dependencies**: NGINX LXC for proxy, Node Exporter on monitored systems

### 4. n8n
- **OS**: Debian 12
- **Resources**: 2 CPU cores, 4GB RAM, 20GB storage
- **Network**: Static IP, bridged network for connections to PostgreSQL, Redis, and Docker
- **Packages**:
  - Docker (`docker.io`, `docker-compose`)
  - n8n (`docker.n8n.io/n8nio/n8n:latest` Docker image)
- **Storage**: ZFS dataset `/quickOS/n8n_data` mounted at `/var/lib/docker`
- **Configuration**:
  - Connects to PostgreSQL (`personal_db`) and Redis for queuing
  - Accessible via NGINX at `/n8n`
  - Workflows for backups, container management, and AI tasks
- **Dependencies**: PostgreSQL LXC, Redis LXC, NGINX LXC

### 5. Redis
- **OS**: Debian 12
- **Resources**: 1 CPU core, 2GB RAM, 10GB storage
- **Network**: Static IP, bridged network for connections from n8n and NGINX
- **Packages**:
  - Redis (`redis-server`)
- **Storage**: ZFS dataset `/quickOS/redis_data` mounted at `/var/lib/redis`
- **Configuration**:
  - Bind to `0.0.0.0` for LXC network access
  - Optional password for security
- **Dependencies**: None

### 6. Portainer
- **OS**: Debian 12
- **Resources**: 1 CPU core, 2GB RAM, 10GB storage
- **Network**: Static IP, bridged network for Docker management
- **Packages**:
  - Docker (`docker.io`, `docker-compose`)
  - Portainer (`portainer/portainer-ce` Docker image)
- **Storage**: ZFS dataset `/quickOS/portainer_data` mounted at `/var/lib/docker`
- **Configuration**:
  - Manages Docker containers across LXC (including DrProd, DrTest, DrDev) and `thinkheads.ai` environments
  - Accessible via NGINX at `/portainer`
  - Uses Docker Compose for deployments
- **Dependencies**: NGINX LXC, Docker-enabled LXC containers

### 7. vLLM (devstral-small)
- **OS**: Debian 12
- **Resources**: 6 CPU cores, 50GB RAM, 100GB storage
- **Network**: Static IP, bridged network for Cline integration
- **Packages**:
  - NVIDIA drivers (`nvidia-open-575.57.08`, `nvidia-utils-575.57.08`, `libnvidia-compute-575.57.08`)
  - Python (`python3`, `python3-pip`, `python3-venv`)
  - vLLM (`vllm` via pip)
- **Storage**: ZFS dataset `/quickOS/vllm_models` mounted at `/opt/vllm_models`
- **Configuration**:
  - GPU passthrough for one RTX 5060Ti
  - Runs `devstral-small` model, API at `http://<lxc_ip>:8000`
  - Accessible via NGINX at `/vllm`
- **Dependencies**: NGINX LXC, NVIDIA drivers on Proxmox host

### 8. vLLM (Cline Planning Mode)
- **OS**: Debian 12
- **Resources**: 6 CPU cores, 50GB RAM, 100GB storage
- **Network**: Static IP, bridged network for Cline integration
- **Packages**:
  - NVIDIA drivers (`nvidia-open-575.57.08`, `nvidia-utils-575.57.08`, `libnvidia-compute-575.57.08`)
  - Python (`python3`, `python3-pip`, `python3-venv`)
  - vLLM (`vllm` via pip)
- **Storage**: ZFS dataset `/quickOS/vllm_models` mounted at `/opt/vllm_models`
- **Configuration**:
  - GPU passthrough for one RTX 5060Ti (different from `devstral-small`)
  - Runs planning-optimized model, API at `http://<lxc_ip>:8000`
  - Accessible via NGINX at `/vllm-plan`
- **Dependencies**: NGINX LXC, NVIDIA drivers on Proxmox host

### 9. DrProd
- **OS**: Debian 12
- **Resources**: 8 CPU cores, 64GB RAM, 100GB storage
- **Network**: Static IP (e.g., `192.168.1.10`), bridged network for local and external access
- **Packages**:
  - NVIDIA drivers (`nvidia-open-575.57.08`, `nvidia-utils-575.57.08`, `libnvidia-compute-575.57.08`)
  - NVIDIA Container Toolkit (`nvidia-container-toolkit`)
  - Docker (`docker.io`, `docker-compose`)
  - nvtop (via Docker image or custom build)
- **Storage**: ZFS dataset `/quickOS/drprod_data` mounted at `/var/lib/docker`
- **Configuration**:
  - GPU passthrough for both RTX 5060Ti GPUs
  - CUDA MPS enabled for GPU sharing
  - Runs `nvtop` in a Docker container for GPU monitoring
  - Supports Docker Compose for deploying production-ready features
  - Accessible via NGINX at `/drprod-nvtop` (using `ttyd` for web-based terminal)
  - Base configuration for cloning to `DrTest` and `DrDev`
- **Dependencies**: NGINX LXC, NVIDIA drivers on Proxmox host

### 10. DrTest
- **OS**: Debian 12 (cloned from `DrProd`)
- **Resources**: 8 CPU cores, 64GB RAM, 100GB storage
- **Network**: Static IP (e.g., `192.168.1.11`), bridged network for local and external access
- **Packages**:
  - NVIDIA drivers (`nvidia-open-575.57.08`, `nvidia-utils-575.57.08`, `libnvidia-compute-575.57.08`)
  - NVIDIA Container Toolkit (`nvidia-container-toolkit`)
  - Docker (`docker.io`, `docker-compose`)
  - nvtop (via Docker image or custom build)
- **Storage**: ZFS dataset `/quickOS/drtest_data` mounted at `/var/lib/docker`
- **Configuration**:
  - Cloned from `DrProd` with updated IP and storage
  - GPU passthrough for both RTX 5060Ti GPUs
  - CUDA MPS enabled for GPU sharing
  - Runs `nvtop` in a Docker container for GPU monitoring
  - Supports Docker Compose for deploying testing features
  - Accessible via NGINX at `/drtest-nvtop` (using `ttyd` for web-based terminal)
- **Dependencies**: NGINX LXC, NVIDIA drivers on Proxmox host

### 11. DrDev
- **OS**: Debian 12 (cloned from `DrProd`)
- **Resources**: 8 CPU cores, 64GB RAM, 100GB storage
- **Network**: Static IP (e.g., `192.168.1.12`), bridged network for local and external access
- **Packages**:
  - NVIDIA drivers (`nvidia-open-575.57.08`, `nvidia-utils-575.57.08`, `libnvidia-compute-575.57.08`)
  - NVIDIA Container Toolkit (`nvidia-container-toolkit`)
  - Docker (`docker.io`, `docker-compose`)
  - nvtop (via Docker image or custom build)
- **Storage**: ZFS dataset `/quickOS/drdev_data` mounted at `/var/lib/docker`
- **Configuration**:
  - Cloned from `DrProd` with updated IP and storage
  - GPU passthrough for both RTX 5060Ti GPUs
  - CUDA MPS enabled for GPU sharing
  - Runs `nvtop` in a Docker container for GPU monitoring
  - Supports Docker Compose for deploying development features
  - Accessible via NGINX at `/drdev-nvtop` (using `ttyd` for web-based terminal)
- **Dependencies**: NGINX LXC, NVIDIA drivers on Proxmox host

## Additional Notes
- **Storage**: All tools and environments use ZFS datasets under `/quickOS` for persistent storage, leveraging Proxmox’s snapshot and backup capabilities.
- **Networking**: All LXC containers use a bridged network with static IPs for reliable communication.
- **Security**: Use unprivileged LXC containers, restrict network access with Proxmox’s firewall, and enable HTTPS via NGINX with basic authentication for sensitive endpoints.
- **Automation**: n8n automates deployment tasks (e.g., Docker Compose deployments, cloning), and Portainer manages Docker containers across `DrProd`, `DrTest`, and `DrDev`.
- **External Access**: NGINX with Let’s Encrypt and Cloudflare ensures secure external access to Proxmox and tools.
- **GPU Management**: CUDA MPS is enabled in `DrProd`, `DrTest`, and `DrDev` to manage GPU sharing, with `nvtop` providing real-time monitoring.
- **Deployment**: `DrProd` is fully configured with Docker Compose templates, which are cloned to `DrTest` and `DrDev` for consistent feature deployment, managed via Portainer and automated with n8n.