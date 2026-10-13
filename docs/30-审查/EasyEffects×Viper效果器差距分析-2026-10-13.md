# EasyEffects × Viper 对照：AuraDSP 效果器差距分析（2026-10-13）

> 基线：AuraDSP 现有 15 链节点（bassmono/tube/comp/bass/eq/arbmag/convolver/ddc/
> liveprog/crossfeed/stereo/haas/exciter/reverb/output）+ 非链节点（input gate、shelf
> 低频搁架、P-010 每效果自动增益/输出门）。
> 对照源：EasyEffects（GNOME 主流）、Viper4Windows（经典安卓味全家桶）。

## 1. 现状盘点（已有 ≈ Viper 覆盖度最高的部分）

| 类别 | EasyEffects | Viper | AuraDSP |
|---|---|---|---|
| 均衡 | 10/15/31 段 + 动态 EQ | FIR EQ | 15 段 + 任意响应（arbmag）✅ |
| 卷积 | Convolver | Convolver(WAV/IRS) | ✅ |
| 空间校正 | - | DDC | ✅（VDC） |
| 混响 | Reverb | Reverberation | ✅（Freeverb） |
| 压限 | 单带/多带压缩 | FET/多带 | 单带 ✅（多带缺） |
| 限幅 | Limiter | - | ✅（输出级） |
| 展宽 | Stereo Tools | Field Surround / Stereo Imager | ✅（stereo 分带） |
| 差分环绕 | - | Differential Surround | ✅（Haas，可切左右） |
| 串扰 | Crossfeed | CURe | ✅ |
| 电子管 | - | Tube Simulator | ✅ |
| 激励 | Exciter / Crystalizer | XClarity | ✅（tanh 高频谐波） |
| 低频 | Bass Enhancer / Loudness | XBass（3 模式） | ✅ bass + bassmono |
| 可编程 | - | - | ✅ liveprog（独有） |
| 响度校准 | Auto gain（一键测量） | Playback AGC | △（实时 leveler，非静态校准） |

## 2. 差距清单（按投入产出排序）

### 高价值 / 中等工作量
| 效果 | 来源 | 说明 | 工作量 |
|---|---|---|---|
| **动态 EQ**（每带门限/attack/release） | EasyEffects + Viper 都有 | 现代感关键：只在目标频段超阈值时增益/压缩。可先从**单带 Deesser 特例**做起 | 1~2 周 |
| **心理声学低音** | Viper 招牌 | 小耳塞"听出下潜"：在可闻频段合成低次谐波（MaxxBass 路线），与现有 bass 直给增益互补 | 3~5 天 |
| **噪声门 Gate** | EasyEffects | 直播/录音刚需：阈值 + attack/release + 保持；与我们刚做的 leveler 结构同源 | 2~3 天 |
| **Deesser** | EasyEffects | 齿音（s 音）压平：4~8kHz 侧链压缩，可视为动态 EQ 的骨架 | 2~3 天 |
| **独立滤波器 HP/LP/BP** | EasyEffects | EQ 能近似但不是真滤波；一阶到四阶，滑块友好 | 2 天 |

### 中价值 / 中等工作量
| 效果 | 来源 | 说明 | 工作量 |
|---|---|---|---|
| **Loudness 响度补偿** | EasyEffects | 等响曲线补偿，小音量回升高低频（人耳 40 phon 曲线） | 3~5 天 |
| **多带压缩（3~5 带）** | EasyEffects + Viper | 有单带底子，但分频交叉 + 联动增益是新增复杂度 | 1~2 周 |
| **Delay/Echo**（非 Haas） | EasyEffects | 真正的反馈延迟 + 节拍同步 + 乒乓；Haas 只是它的 0 反馈特例 | 3~4 天 |
| **立体声相位/中侧工具** | EasyEffects Stereo Tools | phase invert、mid/side 独立增益；现有展宽只有幅度 | 2~3 天 |

### 低价值 / 大工作量（明确不跟或远期）
| 效果 | 说明 |
|---|---|
| Headphone Surround+（HRTF） | 与之前 Dolby 讨论收敛：开放 HRTF 单独立项，可复用 convolver IR 加载器做静态 HRTF |
| Crystalizer | 空气感比 exciter 强（comb 延迟式），但 exciter 已覆盖 80% 听感 |
| Playback AGC / LUFS 目标 | 需 EBU R128 计量 + 长时间包络，工程量大；我们已有实时 leveler 替代 |
| Spectrum Extension VSE | 小众 |
| Speaker Optimization | 设备向，与平台无关 |
| ViPER Bass 三模式细分 | 可做成 bass 卡的模式选择，非新效果器 |

## 3. 快速赢（可利用现有资产）
- **Gate / Deesser / 滤波器**：都可用 `liveprog` EEL 脚本先验证味道（同三件套打法），对味再 nativize。Gate 脚本 20 行内。
- **心理声学低音**：Arbmag + 谐波发生器组合即可原型。
- **动态 EQ**：先做单带 Deesser，再扩到 3~5 带动态 EQ，两次迭代各可控。

## 4. 建议路线
| 批次 | 内容 | 规模 |
|---|---|---|
| 快赢 | Gate + Deesser + 独立滤波器（复用 leveler/侧链基建） | 约 1 周 |
| 招牌 | 心理声学低音 + Loudness 补偿 | 约 1 周 |
| 现代 | 动态 EQ（Deesser 起步）→ 多带压缩 | 2~3 周分期 |
| 远期 | HRTF 环绕、AGC/LUFS、Crystalizer | 单独立项 |

优先级一句话：**动态 EQ 是 EasyEffects 和 Viper 都有的最大空白，且 Deesser 是它的天然第一步**；心理声学低音是 Viper 听感最独特的招牌。
