# CPU 卡工具：目录、文件和余额

打开 **工具 → CPU 卡管理**，选卡后在左侧打开应用或文件。卡片公布的目录条目与本次实际选中的文件会出现在树中。只知道 FID 或绝对路径时，可以用树顶的手动打开入口。未公布的 EF 仍可能存在；目录中的 AID 也可能已失效。

## 实际卡片的读写与保存

- 右侧显示解析结果和原始字节。普通二进制 EF 可按偏移、长度分段读取；记录 EF 按记录号读取。某段数据可原样导出为 BIN，不会补零，也不带 APDU 状态字。
- **写入文件**选择实际 EF 后，可以录入 HEX 或导入 BIN。二进制写入按短 APDU 能承载的大小分段；记录写入仍是一条更新指令。遇到文件安全状态不满足，可以为被拒绝的那一条指令认证一次，已确认的前置分段不会重发。中途停止时显示已确认的字节数。
- 用 **新建目录**选择实际父目录。创建和删除使用 ISO 文件管理命令，是否允许、以及是否需要发卡工具的专用模板，由卡片决定。
- **保存目录**可以存入 CPU 卡库，或导出可以重新导入卡库的 JSON。快照记录树、已知文件参数、记录号或字节偏移、原始数据、状态字和已知的未找到条目；没读到的文件没有内容。关闭射频后仍可保存，同一页重选卡会开始新的快照。快照不是可写回的镜像，不含 PIN、密钥或余额；不会装载到卡槽。

白卡不需要预先有子目录。点 **新建目录**，父目录可用预填的 `3F00`；如果选中的是现有可管理的 DF，则直接在它下面新建。若选 `3F00` 返回 PSE 等目录名，工具会尝试标准 SELECT 的其他格式。只有卡片响应能确认 FID `3F00` 时，才把这个有歧义的选择用于创建。若仍无法确认，可按已知 FID／AID 打开实际父目录，或用配套发卡工具查看卡片的初始化状态。SFI 目录记录返回 `6A82` 只说明本次读不到那个目录记录，不决定主文件是否可用。

### FMCOS 2.0 兼容入口

FMCOS 2.0 的主文件默认为 `3F00`，名称可以是 `1PAY.SYS.DDF01`。手册 §7.4 的实际例子返回 `6F 15 … A5 03 88 01 01`，没有 FID 标签。打开主文件时如果收到和这个例子完全一致的 FCI，右侧会给出 **按 FMCOS 打开 3F00**。此按钮用手册中的不带 Le 的 SELECT 重新选主文件；成功并得到同一 FCI 后才对本次会话启用兼容模式。FID 或名称本身不能鉴定具体芯片。

随后点 **新建目录**，按 FMCOS 2.0 §7.13 的子 DF 模板确认目标 FID、目录名、空间和访问属性。默认值是可改的测试示例；应用文件 ID `95` 取自手册的 `0015` 示例，会话不会为它创建 EF 或登记 PSE 记录。这里只创建现有主文件下的子 DF；不发建主文件、擦除或密钥命令，也不在卡片拒绝后自动改用其他写入格式。实现参考：[复旦微 FMCOS 2.0 用户手册 §7.4、§7.13](https://www.fongwah.com/uploads/files/%E6%96%B0%E7%89%88FMCOS2.0%E7%94%A8%E6%88%B7%E6%89%8B%E5%86%8C.pdf)、[Proxmark3 的 FMCOS 实现](https://github.com/RfidResearchGroup/proxmark3/blob/master/client/src/cmdhffmcos.c)。

## 解析覆盖

| 匹配依据 | 解析内容 | 参考 |
| --- | --- | --- |
| ISO 7816 SELECT 的 FCI/FCP | DF 或 EF、文件描述符、FID/AID、大小和记录参数；生命周期与安全属性保留为字段原值。识别 BER-TLV 数据对象 EF 与内部 EF，避免误当成普通二进制文件。 | [ISO/IEC 7816-4](https://www.iso.org/standard/77180.html)、[ETSI TS 102 221 §11.1.1.4](https://www.etsi.org/deliver/etsi_ts/102200_102299/102221/17.01.00_60/ts_102221v170100p.pdf)、[OpenSC](https://github.com/OpenSC/OpenSC/blob/master/src/libopensc/iso7816.c) |
| MF 下实际打开的 EF.DIR（`2F00`） | 应用模板 `61`、AID `4F`、标签 `50`、可选路径 `51`。 | [ETSI TS 102 221 §13.1](https://www.etsi.org/deliver/etsi_ts/102200_102299/102221/17.01.00_60/ts_102221v170100p.pdf) |
| EMV PSE 或 PPSE 公布的应用目录 | PSE 记录 `70/61`、PPSE 内嵌记录、应用标识及标签、DDF 名称和优先级标志。长度不符时保留原始记录和诊断。 | [EMVCo Book 1 v4.4](https://www.emvco.com/emvco-website-search/?post_id=80379&type=specifications)、[EMV Contactless](https://www.emvco.com/emv-technologies/emv-contactless-chip/) |
| NFC Forum Type 4 应用公布的 CC 与 NDEF EF | CC 映射版本、MLe/MLc、文件大小与读写权限；从 NLEN/ENLEN 读取消息，并解析 Text/URI 记录。只自动预览至 4 KiB，未读全会标出；未知、分块或异常消息保留原字节，URI 不自动打开。功能页不提供通用 NDEF 更新。 | [NFC Forum Type 4](https://nfc-forum.org/build/specifications/type-4-tag-specification)、[NXP AN11004](https://www.nxp.com/docs/en/application-note/AN11004.pdf)、[nfcpy](https://github.com/nfcpy/nfcpy/blob/master/src/nfc/tag/tt4.py) |
| 住建部互联互通 `A00000000386980701` 或交通联合 `A000000632010105` 已成功选中 | 点 **读取应用基本信息**，使用实际响应的二进制短文件号 `0x15`（十进制 21）。显示已确认布局的版本、日期，以及住建部卡的城市代码。SFI 与 FID 不是同一个地址，界面不会将其猜为 FID `0015`。 | NFCard 的 [CityUnion](https://github.com/sinpolib/nfcard/blob/master/src/com/sinpo/xnfc/nfc/reader/pboc/CityUnion.java)、[TUnion](https://github.com/sinpolib/nfcard/blob/master/src/com/sinpo/xnfc/nfc/reader/pboc/TUnion.java)、[StandardPboc](https://github.com/sinpolib/nfcard/blob/master/src/com/sinpo/xnfc/nfc/reader/pboc/StandardPboc.java) |

没有卡种和文件地址依据时继续显示原始字节。公开实现可用于核对常见布局，不能保证各地、各代卡片或 COS 换版后仍采用相同定义。

## 为什么钱包 EF 看得到，余额仍要另外查询

发卡软件可以按卡片模板列出专用钱包 EF。一个可核对的例子是交通运输部《收费公路联网收费技术标准》JTG 6310—2022，表 L.2.2-5 将 ETC 用户卡的钱包列为 FID `0002`，同时把它定义为专用钱包文件，金额由 COS 管理，内部长度和编码也由 COS 定义。该 FID 不能从这份标准套用到其他卡种。参见[交通运输部标准原文](https://xxgk.mot.gov.cn/jigou/glj/202209/P020220920609041050671.pdf)。

当前住建部互联互通卡在应用详情点 **查询余额** 后，按 [NFCard 的实现](https://github.com/sinpolib/nfcard/blob/master/src/com/sinpo/xnfc/nfc/reader/pboc/StandardPboc.java) 调用电子钱包的余额命令。收到成功状态和可识别的四字节金额才显示读数。真正读到的零显示为 `0.00 元`，卡片拒绝或返回不符合格式时显示错误。余额不混入 EF 的 BIN 或目录快照。交通联合的透支和余额规则不同，这版只解析它的基本信息。
