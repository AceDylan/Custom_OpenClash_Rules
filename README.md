bash <(curl -sL https://raw.githubusercontent.com/AceDylan/Custom_OpenClash_Rules/main/scripts/install_motd.sh)   VPS显示容器信息脚本
参考 bash <(curl -sL https://raw.githubusercontent.com/shanchuanbei/ssh/refs/heads/main/install_motd.sh) 实现，增加了 immortwal 系统兼容
cfg/Custom_Clash.ini 的分组段（应用→出口→线路三层）由私有仓库 openclash-ops 的 topology.yaml 生成，请勿手改；分流规则仍在本仓库 rule/ 与 INI 规则段维护。路由器机器人、覆写与定时任务也已迁到 openclash-ops。

