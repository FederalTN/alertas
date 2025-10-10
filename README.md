sudo apt update && sudo apt upgrade -y

# Paquetes básicos de desarrollo
sudo apt install -y git curl wget unzip build-essential pkg-config libssl-dev libgtk-3-dev liblzma-dev libasound2-dev libpulse-dev

# Python 3 + venv + pip
sudo apt install -y python3 python3-venv python3-pip

# Flutter + Android SDK deps (si no los tenías)
sudo apt install -y clang cmake ninja-build libgtk-3-dev libblkid-dev liblzma-dev libstdc++-12-dev libsecret-1-dev


# Clonar tu repositorio o crear carpeta
mkdir -p ~/Projects/ServerPython
cd ~/Projects/ServerPython

# Crear entorno virtual
python3 -m venv .venv
source .venv/bin/activate

# Instalar dependencias
pip install --upgrade pip
pip install fastapi uvicorn python-dotenv

# (Opcional si vas a subir archivos grandes y CSV)
pip install python-multipart

# Crea los archivos
#   server.py    (el que te di)
#   .env         (opcional, puedes dejarlo vacío o con valores como)
cat > .env <<'EOF'
PORT=4000
HOST=0.0.0.0
UPLOAD_DIR=audios
CSV_PATH=registros.csv
EOF

# Ejecutar el servidor
uvicorn server:app --host 0.0.0.0 --port 4000 --reload
