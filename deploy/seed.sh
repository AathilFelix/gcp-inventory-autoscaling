#!/usr/bin/env bash
# Loads sample products through the public load balancer (also a quick end-to-end check).
set -euo pipefail
cd "$(dirname "$0")"
source ./config.sh
IP="$(gcloud --project="${PROJECT_ID}" compute addresses describe "${LB_IP_NAME}" --global --format='value(address)')"

add() { # sku name category price qty reorder
  curl -s -o /dev/null -w "%{http_code} $1\n" -X POST "http://${IP}/api/products" -H 'Content-Type: application/json' \
    -d "{\"sku\":\"$1\",\"name\":\"$2\",\"category\":\"$3\",\"price\":$4,\"quantity\":$5,\"reorder_level\":$6}"
}

add LAP-1001 "Business Laptop 14in"        Computers    58990 24 5
add LAP-1002 "Gaming Laptop 15in"          Computers    94990 8  5
add MON-2001 "27in 4K Monitor"             Displays     26990 31 8
add KEY-3001 "Mechanical Keyboard"         Accessories  4290  120 25
add MOU-3002 "Wireless Mouse"              Accessories  799   260 40
add HDS-3003 "Noise Cancelling Headset"    Audio        8990  4   10
add WEB-3004 "1080p Webcam"                Accessories  2490  57  15
add SSD-4001 "1TB NVMe SSD"                Storage      7490  75  20
add HDD-4002 "2TB External Drive"          Storage      5990  3   10
add RTR-5001 "Wi-Fi 6 Router"              Networking   6490  42  10
add CAB-5002 "Cat6 Cable 10m"              Networking   349   400 100
add PRN-6001 "Laser Printer"               Printers     14990 12  4
