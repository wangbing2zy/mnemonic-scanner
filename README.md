# 助记词批量扫描工具

批量扫描数十万组 BIP39 助记词，快速定位有钱包地址的 Web 工具。

## 功能特点

- **多链支持**：Ethereum、BSC、Polygon、Arbitrum、Optimism、Bitcoin、Solana、TRON
- **Web 后台**：基于 FastAPI 的 Web 界面，实时显示扫描进度
- **高效扫描**：多进程派生地址 + 异步并发检查余额
- **导出结果**：支持 CSV / JSON 格式导出有钱包地址
- **零外部依赖**：使用 SQLite 存储数据，无需额外数据库服务

## 系统要求

- Python 3.9+
- 操作系统：Ubuntu 22.04 / macOS / Linux
- 推荐：2 核 CPU、2GB 内存

## 快速开始

### 方式一：Docker 部署（推荐）

```bash
# 1. 克隆项目
git clone https://github.com/your-username/mnemonic-scanner.git
cd mnemonic-scanner

# 2. 修改配置（可选）
vim .env

# 3. 启动
docker-compose up -d

# 4. 访问
open http://localhost:8000
```

### 方式二：直接部署

```bash
# 1. 克隆项目
git clone https://github.com/your-username/mnemonic-scanner.git
cd mnemonic-scanner

# 2. 安装依赖
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# 3. 启动
python run.py

# 4. 访问
open http://localhost:8000
```

### 方式三：一键部署（Ubuntu 22.04）

```bash
# 以 root 用户执行
bash deploy.sh
```

## 使用流程

### 1. 上传助记词
- 准备 `.txt` 文件，每行一组 BIP39 助记词（12/15/18/21/24 个单词）
- 在 Web 界面上传文件
- 自动校验格式，跳过无效行

### 2. 配置扫描
- 选择目标区块链（可多选）
- 设置并发数（并发越高越快，但可能被 API 限流）

### 3. 实时扫描
- Phase 1：**地址派生** — 将助记词派生出各链地址（CPU 密集）
- Phase 2：**余额检查** — 通过公共 RPC 查询各地址余额（IO 密集）
- 实时进度条 + SSE 推送

### 4. 导出结果
- 扫描完成后查看有钱包地址列表
- 导出 CSV / JSON 格式

## 支持的区块链

| 链 | 标识 | 余额查询方式 | RPC 端点 |
|----|------|-------------|---------|
| Ethereum | eth | `eth_getBalance` | eth.llamarpc.com / ankr.com |
| BSC | bsc | `eth_getBalance` | bsc-dataseed.binance.org |
| Polygon | polygon | `eth_getBalance` | polygon-rpc.com |
| Arbitrum | arbitrum | `eth_getBalance` | arb1.arbitrum.io/rpc |
| Optimism | optimism | `eth_getBalance` | mainnet.optimism.io |
| Bitcoin | btc | Blockstream API | blockstream.info |
| Solana | sol | `getBalance` | api.mainnet-beta.solana.com |
| TRON | trx | TronGrid API | api.trongrid.io |

## 项目结构

```
├── app/
│   ├── config.py       # 配置（RPC 端点、链参数等）
│   ├── database.py     # SQLAlchemy 模型 + SQLite
│   ├── main.py         # FastAPI 路由 + 入口
│   ├── scanner.py      # 核心引擎（派生 + 检查 + 任务管理）
│   └── templates/      # Jinja2 模板
├── requirements.txt    # Python 依赖
├── Dockerfile          # Docker 构建文件
├── docker-compose.yml  # Docker Compose 配置
├── deploy.sh           # Ubuntu 一键部署脚本
└── .env                # 环境变量配置
```

## 环境变量

在 `.env` 文件中配置：

| 变量 | 默认值 | 说明 |
|------|--------|------|
| HOST | 0.0.0.0 | 监听地址 |
| PORT | 8000 | 监听端口 |
| WORKERS | 2 | 工作进程数 |
| DEFAULT_CONCURRENCY | 10 | 默认并发数 |
| MAX_UPLOAD_SIZE_MB | 500 | 文件上传大小限制 |
| ETH_RPC | https://eth.llamarpc.com | Ethereum RPC |
| BSC_RPC | https://bsc-dataseed.binance.org | BSC RPC |
| BLOCKSTREAM_API | https://blockstream.info/api | BTC API |
| SOLANA_RPC | https://api.mainnet-beta.solana.com | Solana RPC |
| TRON_GRID_API | https://api.trongrid.io | TRON API |

## 安全提示

- 请确保服务器安全，使用 HTTPS + 防火墙
- 建议设置 Nginx 反向代理 + 基础认证
- 定期备份 `data/scanner.db` 数据库文件
- 扫描完成后及时导出结果并清理敏感数据
