# v3 standing-image / first-frame audit

Catalogue SHA256: `75881cf91621c967f80732f0219f23e85b35e8bde5d1a51ee75dec5f7c5edd36`.

Compared 219 actions; **187** differ under the documented lossy tolerance. Original media were not changed.

Decode packed video frame 0; compare RGBA at 320 square against unchanged cover. Silhouette alpha >=128; IoU >=0.95 and foreground composite MAE <=8 on white/dark backgrounds. Lossy tolerance is an audit heuristic, not visual acceptance.

The SDK bundles the original alpha WebP covers byte-for-byte. Where the cover differs from frame zero, a 180 ms fade preserves placement but cannot guarantee an identical pose; a source-media correction requires separate approval.

| ID | Chinese name | Cover frame | Silhouette IoU | Foreground MAE |
| --- | --- | ---: | ---: | ---: |
| `abs-A` | 空心体支撑 | 66 | 0.6148 | 65.29 |
| `abs-B` | 平行杆团身 L 撑 | 135 | 0.6305 | 58.57 |
| `adductors-A` | 哥萨克蹲 | 59 | 0.0766 | 160.96 |
| `adductors-B` | 屈膝哥本哈根侧撑 | 72 | 0.9103 | 13.95 |
| `adductors-C` | 绳索站姿髋内收 | 48 | 0.7854 | 37.69 |
| `chest-A` | 俯卧撑转侧撑 | 86 | 0.2945 | 120.42 |
| `chest-B` | 平行杆深幅俯卧撑 | 63 | 0.2765 | 127.56 |
| `chest-C` | 绳索单臂站姿推胸 | 45 | 0.8822 | 14.27 |
| `deltoids-A` | 直臂侧平板支撑 | 63 | 0.4014 | 94.42 |
| `deltoids-B` | 哑铃半程土耳其起立（至高桥） | 120 | 0.7331 | 51.49 |
| `deltoids-C` | 地雷杆半跪单臂推举 | 48 | 0.6413 | 52.55 |
| `erectors-A` | 反向平板（后撑抬髋） | 78 | 0.4043 | 108.48 |
| `erectors-B` | 瑞士球背伸 | 60 | 0.7281 | 44.21 |
| `erectors-C` | 45° 罗马椅背伸 | 15 | 0.8667 | 18.84 |
| `forearms-A` | 跪姿多方向腕部摇摆 | 35 | 0.8179 | 36.26 |
| `forearms-B` | 哑铃腕屈 + 腕伸 | 48 | 0.9031 | 16.36 |
| `g-cable-hip-abduction` | 低位绳索髋外展 | 60 | 0.8840 | 20.61 |
| `g-cable-hip-extension` | 低位绳索髋后伸 | 60 | 0.9451 | 9.39 |
| `glute-max-A` | 单腿臀桥 | 63 | 0.6054 | 78.55 |
| `glute-max-B` | 弹力带四足直腿后踢 | 57 | 0.7712 | 42.96 |
| `glute-max-C` | 反向背伸机 | 39 | 0.5180 | 79.23 |
| `h-9090-liftoff` | 90/90 后腿主动抬起 | 60 | 0.9397 | 15.19 |
| `h-adductor-rock` | 四足单腿侧伸后摇 | 72 | 0.8679 | 27.17 |
| `h-banana` | 仰卧香蕉式侧伸 | 72 | 0.9279 | 26.03 |
| `h-band-chest-fly` | 站姿单臂弹力带夹胸 | 60 | 0.9004 | 18.42 |
| `h-band-face-pull` | 站姿弹力带面拉 | None | 0.8796 | 15.67 |
| `h-band-hip-extension` | 扶椅弹力带髋后伸 | 60 | 0.8924 | 17.79 |
| `h-band-hip-ir` | 坐椅弹力带髋内旋 | 60 | 0.7739 | 38.69 |
| `h-band-leg-out` | 仰卧弹力带单腿侧落 | 120 | 0.9187 | 17.90 |
| `h-band-pallof` | 弹力带抗旋转推 | 60 | 0.7215 | 44.36 |
| `h-band-pull-apart` | 弹力带水平拉开 | 60 | 0.6214 | 52.12 |
| `h-band-row` | 弹力带坐姿划船 | 60 | 0.7743 | 34.77 |
| `h-band-shoulder-ir` | 弹力带站姿肩内旋 | 60 | 0.9639 | 8.38 |
| `h-band-standing-abduction` | 扶椅弹力带站姿外展 | 60 | 0.8122 | 32.13 |
| `h-band-standing-adduction` | 弹力带站姿内收 | 60 | 0.8165 | 31.56 |
| `h-band-stepout` | 弹力带侧向步出抗旋转 | 108 | 0.3944 | 105.76 |
| `h-band-straight-leg-raise` | 扶椅弹力带直腿前抬 | 60 | 0.8563 | 22.62 |
| `h-band-triceps-pressdown` | 站姿单臂弹力带下压 | 60 | 0.8625 | 18.88 |
| `h-bent-knee-calf-raise` | 屈膝承重提踵 | None | 0.8399 | 28.16 |
| `h-bilateral-upper-back-hug` | 双臂前抱上背拉伸 | None | 0.9061 | 15.37 |
| `h-bulgarian` | 椅子保加利亚分腿蹲 | 6 | 0.9392 | 6.09 |
| `h-butterfly-active` | 仰卧蝴蝶主动开合 | 69 | 0.8887 | 25.83 |
| `h-calf-raise` | 扶墙提踵 | 57 | 0.8370 | 26.85 |
| `h-catcow-quad` | 四足猫牛式 | 39 | 0.8463 | 21.45 |
| `h-chair-dip` | 椅子臂屈伸 | 6 | 0.9351 | 5.44 |
| `h-chair-kickback` | 扶椅站姿后踢腿 | 57 | 0.7024 | 47.18 |
| `h-chair-lat` | 扶椅背阔肌拉伸 | 108 | 0.7007 | 40.87 |
| `h-chair-progressive-front-split-native` | 扶椅前后劈叉渐进 | None | 0.8252 | 33.10 |
| `h-chair-single-leg-hip-thrust` | 肩靠椅单腿臀推 | None | 0.5568 | 79.87 |
| `h-chair-sit-to-stand` | 普通椅双脚坐站 | 99 | 0.4075 | 98.94 |
| `h-chair-step-up` | 椅子上步 | 66 | 0.1600 | 138.71 |
| `h-chair-tspine` | 跪姿椅面胸椎伸展 | 66 | 0.6900 | 50.34 |
| `h-close-stance-forward-fold-native` | 并脚微屈膝无扶体前屈 | None | 0.3086 | 112.92 |
| `h-cobra` | 眼镜蛇式 | 66 | 0.6562 | 63.54 |
| `h-couch-stretch` | 沙发拉伸（后脚搭矮凳） | 114 | 0.6897 | 52.85 |
| `h-crunch` | 卷腹 | 57 | 0.7600 | 45.93 |
| `h-db-calf-raise` | 双哑铃站姿提踵 | 60 | 0.5335 | 78.74 |
| `h-db-curl` | 哑铃交替弯举 | 60 | 0.7521 | 33.96 |
| `h-db-front-raise` | 站姿双哑铃前平举 | 60 | 0.8019 | 39.92 |
| `h-db-hammer-curl` | 站姿双哑铃锤式弯举 | 60 | 0.8213 | 32.36 |
| `h-db-kickback` | 双哑铃俯身臂屈伸 | 60 | 0.8112 | 32.89 |
| `h-db-lateral` | 哑铃侧平举 | 60 | 0.6220 | 51.47 |
| `h-db-overhead-triceps-extension` | 单臂哑铃过头臂屈伸 | None | 0.8559 | 24.71 |
| `h-db-press` | 站姿哑铃推举 | 60 | 0.5850 | 59.28 |
| `h-db-reverse-fly` | 哑铃俯身飞鸟 | 60 | 0.6150 | 55.80 |
| `h-db-row` | 扶椅单臂哑铃划船 | 60 | 0.8061 | 33.80 |
| `h-db-shrug` | 双哑铃站姿耸肩 | 60 | 0.8860 | 20.44 |
| `h-db-supported-calf-raise` | 单手哑铃扶墙双脚提踵 | 60 | 0.9285 | 14.61 |
| `h-dd-shoulder` | 下犬式压肩 | 66 | 0.7932 | 36.69 |
| `h-donkey-kick` | 四足屈膝后踢 | 57 | 0.8115 | 35.66 |
| `h-doorframe-forearms-pec-native-r3` | 门框双前臂胸肌拉伸 | None | 0.9213 | 10.23 |
| `h-fixed-bar-vertical-pull` | 固定单杠舒适范围引体 | None | 0.8039 | 34.35 |
| `h-floor-nordic-hand-reset` | 地面北欧离心及手撑复位 | None | 0.4780 | 88.91 |
| `h-forearm-plank` | 前臂平板支撑 | 63 | 0.9280 | 15.61 |
| `h-forward-lunge` | 前跨步弓步蹲 | None | 0.1806 | 141.72 |
| `h-hip-gate` | 扶椅站姿开髋门 | 48 | 0.7497 | 37.30 |
| `h-knee-hug` | 仰卧抱膝 | 75 | 0.8754 | 24.55 |
| `h-knee-wall-dorsiflexion-native` | 膝碰墙背屈（前脚跟不离地） | None | 0.9186 | 19.54 |
| `h-kneeling-instep-stretch` | 跪姿脚背支撑拉伸 | None | 0.8127 | 29.41 |
| `h-kneeling-pushup` | 跪姿俯卧撑 | None | 0.5163 | 73.89 |
| `h-kneeling-thread-needle` | 跪姿低位穿针（小范围修订） | None | 0.7730 | 29.83 |
| `h-lateral-step-lunge` | 侧跨步弓步蹲 | None | 0.1652 | 145.16 |
| `h-plank-side-step` | 直臂俯撑交替侧点地 | 48 | 0.9224 | 12.09 |
| `h-quad-cars` | 四足髋关节画圈 | 66 | 0.9089 | 20.59 |
| `h-quadruped-open` | 四足跪姿单臂开胸 | None | 0.7972 | 34.13 |
| `h-quadruped-rockback` | 四足中立背后坐 | None | 0.8072 | 35.14 |
| `h-reverse-clam` | 侧卧反向蚌式 | 54 | 0.8716 | 25.55 |
| `h-reverse-crunch` | 反向卷腹 | 30 | 0.7264 | 48.80 |
| `h-russian-twist` | 俄罗斯转体 | 30 | 0.8463 | 27.48 |
| `h-seated-reachback` | 坐姿后撑滑臀 | 120 | 0.7294 | 47.15 |
| `h-side-er` | 侧卧肩外旋 | 54 | 0.8751 | 21.85 |
| `h-side-leg-raise` | 站姿侧抬腿 | 57 | 0.6876 | 49.28 |
| `h-slider-body-saw` | 双脚滑盘长杠杆回收 | 66 | 0.5449 | 75.10 |
| `h-step-jack` | 低冲击开合跳 | 60 | 0.2963 | 118.82 |
| `h-suitcase-march` | 单手哑铃交替踏步抗侧屈 | 60 | 0.4419 | 97.35 |
| `h-sumo-pry` | 相扑深蹲肘推膝停留 | 78 | 0.6060 | 71.30 |
| `h-superman` | 俯卧超人式 | 66 | 0.6014 | 67.67 |
| `h-supine-bilateral-leg-raise` | 仰卧双直腿举腿 | None | 0.7517 | 47.79 |
| `h-supine-heel-slide` | 仰卧足跟滑 | None | 0.9305 | 15.79 |
| `h-supine-twist` | 仰卧屈膝扭转 | 69 | 0.7820 | 39.64 |
| `h-supported-single-leg-calf` | 扶墙单腿提踵 | 60 | 0.9255 | 16.78 |
| `h-tabletop` | 桌面式后撑抬髋 | 60 | 0.5278 | 84.33 |
| `h-tib-raise` | 靠墙勾脚尖 | 54 | 0.7527 | 41.70 |
| `h-unsupported-star-reach-native` | 无扶单腿三向点地 | None | 0.6087 | 61.96 |
| `h-wall-angel` | 靠墙天使 | 60 | 0.9203 | 16.93 |
| `h-wall-calf` | 靠墙小腿拉伸 | 105 | 0.6129 | 65.66 |
| `h-wall-calf-bent-knee` | 扶墙屈膝小腿拉伸 | 120 | 0.8791 | 21.06 |
| `h-wall-palm-lift` | 墙面指端接触掌根抬起诊断 | None | 0.9533 | 9.48 |
| `h-wall-straddle` | 靠墙仰卧 V 字分腿 | 135 | 0.9548 | 10.87 |
| `h-wall-wrist-flexor-stretch` | 站姿扶墙腕屈肌拉伸 | 105 | 0.9456 | 9.10 |
| `hamstrings-B` | 滑盘腿弯举 | 69 | 0.7456 | 54.95 |
| `hamstrings-C` | GHD 北欧离心 | 144 | 0.3561 | 99.41 |
| `hip-abductors-A` | 侧平板抬腿 | 48 | 0.8610 | 26.42 |
| `hip-abductors-B` | 仰卧弹力带 V 字开腿 | 66 | 0.6171 | 70.23 |
| `hip-abductors-C` | 器械髋外展 | 48 | 0.8172 | 34.78 |
| `hip-flexors-A` | 坐姿直腿抬腿（压缩） | 57 | 0.9363 | 11.60 |
| `hip-flexors-B` | 弹力带站姿高抬膝 | 66 | 0.7775 | 38.89 |
| `hip-flexors-C` | 绳索站姿直腿前抬 | 48 | 0.7838 | 36.38 |
| `lats-A` | 坐姿撑地抬臀 | 63 | 0.8340 | 32.33 |
| `lats-B` | 弹力带直臂下拉 | 3 | 0.8651 | 18.18 |
| `n-chair-wiper` | 坐椅雨刷（膝内倒） | 60 | 0.7811 | 37.84 |
| `n-half-split` | 半跪半劈叉 | 90 | 0.8474 | 28.49 |
| `n-leg-circles` | 仰卧直腿画圈 | 189 | 0.8240 | 33.40 |
| `n-pelvis-circle` | 站姿骨盆画圈 | 33 | 0.7680 | 33.37 |
| `n-prone-hip-ext` | 俯卧屈膝抬腿 | 60 | 0.8634 | 27.92 |
| `n-prone-ir` | 俯卧小腿外摆 | 60 | 0.8514 | 27.91 |
| `n-seated-ir-drop` | 坐姿后撑单膝内倒 | 66 | 0.9146 | 20.04 |
| `n-seated-knee-lift` | 坐姿抬膝悬停 | 60 | 0.8314 | 25.69 |
| `n-seated-squeeze` | 坐姿夹砖（膝内夹） | 60 | 0.8590 | 21.61 |
| `n-slider-lateral` | 滑垫侧向滑 | 60 | 0.3425 | 119.31 |
| `n-squat-shift` | 低位蹲姿左右移重心 | 66 | 0.5590 | 82.75 |
| `n-straddle-fold` | 坐姿分腿体前屈 | 90 | 0.9081 | 20.43 |
| `n-thomas-test` | 仰卧单膝抱胸 | 75 | 0.8963 | 19.80 |
| `n-wide-fold` | 站姿宽距体前屈（扶椅） | 90 | 0.7169 | 44.57 |
| `n-windshield` | 仰卧雨刷式 | 66 | 0.9236 | 19.19 |
| `o-chair-knee-extension` | 坐椅徒手伸膝 | None | 0.8508 | 25.45 |
| `o-seated-calf-raise` | 坐椅提踵 | None | 0.8687 | 24.78 |
| `o-seated-catcow` | 坐姿猫牛式 | 78 | 0.7626 | 34.08 |
| `o-seated-fig4` | 坐姿四字前压 | 114 | 0.7404 | 46.79 |
| `o-seated-ham` | 坐姿腘绳肌前伸 | 114 | 0.6303 | 61.53 |
| `o-seated-hip-er` | 坐椅无阻力髋外旋控制 | 105 | 0.9005 | 14.88 |
| `o-seated-sidebend` | 坐椅单臂侧伸 | None | 0.6512 | 54.76 |
| `o-seated-twist` | 坐姿扶椅扭转 | 114 | 0.8814 | 25.42 |
| `o-stand-crossreach` | 扶椅站姿交叉侧伸 | 114 | 0.7179 | 42.03 |
| `o-stand-ham` | 扶椅站姿单腿腘绳肌拉伸 | 105 | 0.7227 | 48.85 |
| `o-stand-lunge` | 扶椅站姿弓步屈髋拉伸 | 114 | 0.7495 | 43.73 |
| `o-stand-quad` | 扶椅站姿股四头肌拉伸 | 114 | 0.8058 | 31.32 |
| `o-stand-sidebend` | 站姿举手侧屈 | 114 | 0.7250 | 44.37 |
| `o-supported-hip-airplane` | 扶椅单腿髋飞机 | 60 | 0.7553 | 37.60 |
| `o-supported-hip-hitch` | 扶椅单腿骨盆提拉 | 60 | 0.8426 | 20.89 |
| `o-supported-hip-ir` | 扶椅屈膝髋内旋控制 | 60 | 0.9007 | 16.61 |
| `o-supported-knee-curl` | 扶椅站姿徒手屈膝 | 60 | 0.9069 | 16.78 |
| `o-supported-march` | 扶椅站姿交替抬膝 | 60 | 0.9126 | 15.94 |
| `o-supported-mini-squat` | 扶椅浅蹲 | 60 | 0.7710 | 38.92 |
| `o-supported-star-reach` | 扶椅单腿三向点地 | 105 | 0.7362 | 42.62 |
| `o-wall-hip-hinge-stretch` | 扶墙髋后移躯干延展 | 105 | 0.8014 | 33.61 |
| `obliques-A` | 熊爬穿腿 | 60 | 0.5952 | 73.39 |
| `obliques-B` | 弹力带抗旋转推 | 60 | 0.7807 | 34.99 |
| `obliques-C` | 绳索高位伐木 | 30 | 0.7994 | 30.51 |
| `quadriceps-A` | 跪姿反向北欧 | 63 | 0.4729 | 90.71 |
| `quadriceps-B` | 弹力带终末伸膝 | 60 | 0.6325 | 62.85 |
| `quadriceps-C` | 器械腿屈伸（顶端锁直） | 78 | 0.8073 | 32.27 |
| `rotator-cuff-A` | 俯撑交替触肩 | 26 | 0.5428 | 88.69 |
| `rotator-cuff-B` | 弹力带肘贴体侧外旋 | 60 | 0.8822 | 18.05 |
| `rotator-cuff-C` | 绳索 90/90 外旋 | 48 | 0.7298 | 33.85 |
| `s-9090` | 90/90 坐姿换髋 | 114 | 0.8062 | 36.96 |
| `s-butterfly` | 蝴蝶式 | 114 | 0.8237 | 40.57 |
| `s-frog` | 青蛙式 | 114 | 0.9437 | 13.66 |
| `s-kneel-hipflex` | 半跪髋屈肌拉伸 | 114 | 0.6993 | 52.57 |
| `s-lizard` | 蜥蜴式低弓步 | 114 | 0.8546 | 28.71 |
| `s-pigeon` | 鸽子式（直立扶砖版） | 114 | 0.9453 | 9.97 |
| `s-seated-fold` | 坐姿体前屈 | 114 | 0.5910 | 69.03 |
| `scapular-A` | 俯卧 Y-T-W 举 | 26 | 0.8213 | 26.06 |
| `scapular-B` | 单杠肩胛引体 | 57 | 0.7803 | 37.46 |
| `serratus-A` | 俯撑肩胛前伸 | 74 | 0.9057 | 16.33 |
| `serratus-B` | 泡沫轴墙面上滑 | 66 | 0.8336 | 30.57 |
| `serratus-C` | 吊环俯卧撑加前伸 | 18 | 0.6882 | 45.83 |
| `t-seated-straddle-lift-1leg` | 坐姿分腿单腿抬起 | 18 | 0.9358 | 13.49 |
| `triceps-B` | 平行杆直臂支撑 | 105 | 0.6426 | 53.06 |
| `triceps-C` | 双杠臂屈伸 | 18 | 0.7027 | 40.61 |
| `w-bird-dog` | 鸟狗式 | 66 | 0.7622 | 41.57 |
| `w-chair-hip-thrust` | 椅子臀推 | 60 | 0.6042 | 73.95 |
| `w-clamshell` | 侧卧蚌式开合 | 54 | 0.8669 | 25.37 |
| `w-dead-bug` | 死虫式 | 56 | 0.7635 | 39.01 |
| `w-feet-on-chair-bridge` | 脚踩椅面臀桥 | 60 | 0.6154 | 71.79 |
| `w-fire-hydrant` | 四足消防栓 | 57 | 0.8767 | 26.78 |
| `w-prone-swimmer` | 俯卧游泳式 | 22 | 0.8288 | 29.51 |
