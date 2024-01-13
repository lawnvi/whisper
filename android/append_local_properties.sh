# 创建local.properties文件 for github action
LOCAL_FILE="android/local.properties"
cat >> "${LOCAL_FILE}" <<EOF

# keystore
keyAlias=whisper
keyPassword=$1
storeFile=../../keystore/whisper.keystore
storePassword=$2
EOF