wget -N --no-check-certificate https://raw.githubusercontent.com/luckygoal/scripts/main/gost.sh && chmod +x gost.sh && ./gost.sh







wget -N --no-check-certificate https://raw.githubusercontent.com/luckygoal/scripts/main/clone.sh
chmod +x clone.sh
sudo mv clone.sh /usr/local/bin/clone.sh
echo "脚本已安装，请执行： clone.sh"



wget -O /tmp/xray-ipv4.sh \
  https://raw.githubusercontent.com/luckygoal/scripts/main/xray-ipv4.sh \
&& chmod 700 /tmp/xray-ipv4.sh \
&& sudo /tmp/xray-ipv4.sh
