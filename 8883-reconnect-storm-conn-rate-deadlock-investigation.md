# 8883 端口(TLS)重连风暴后连接无法恢复问题调查报告

- **日期**: 2026-08-24(同日依据故障日志证据复核修订:修正 Linux accept 语义与 RST 分类的错误,并以日志数据替换未经证实的"刚性死锁稳态"强结论,见 §1.4/§1.5/§1.6)
- **现象**: 客户 EMQX(企业版 4.4.x,esockd 5.8.12,EMQX 定制 OTP 24.3.4.17)在约 2 万 MQTT 连接批量掉线并发起大并发重连后,8883 端口(TLS)SYN 被 DROP、telnet 极慢,预期"以 30/s 速率慢慢恢复"未发生,约 10 小时后连接总数反而比故障前少了约 10 万。
- **相关配置**:
  - `listener.tcp.external.max_conn_rate = 30`(客户设置,即 `{Capacity=30, Interval=1}` 秒)
  - `acceptors = 16`,`backlog = 1024`(accept 队列)
  - `listener.ssl.external.handshake_timeout = 15s`,`zone.external.idle_timeout = 15s`
  - 平时每秒约 6~9 个连接因 `ssl_error:unknown_ca` 或 JWT 校验失败被应用层断开(正常现象)
- **调查范围**: esockd 源码(`_build/default/lib/esockd/src/`)、EMQX 连接层(`src/emqx_connection.erl` 等)、EMQX 定制 OTP(`otp/erts/emulator/drivers/common/inet_drv.c`、`otp/erts/preloaded/src/prim_inet.erl`)、Linux 内核源码(`linux-3.10.0-1160.2.1.el7`,CentOS 7 同代内核,用于验证 accept 队列死连接行为,见 §1.4)、故障日志定量分析(`mqtt_log/emqx.log.8`、`emqx.log.9`,覆盖 08-19 20:59 → 08-20 13:22)

---

## 0. 结论摘要(一句话)

**令牌在 `accept()` 成功的瞬间被消耗,而 backlog 中的连接若排队超过客户端超时时间,被 accept 出来时早已死亡(Linux 不会把死连接移出 accept 队列,见 §1.4)——死连接白白消耗 accept 名额,把有效建连速率压到远低于 30/s。但日志证据(§1.5)表明这并非"全部喂给死连接"的刚性死锁:故障期间至少约 19% 的令牌被活连接消耗,真实形态是 SYN 率在 30/s 临界点附近波动、队列时满时不满的波动状态(§1.6)。**

"客户端应当以接近 30/s 建立成功"的预期不成立,因为 **30/s 是"accept 速率",不是"成功建连速率"**。这是 esockd 限速模型的设计缺陷(计费点错位 + backlog 反向放大 + 无自适应恢复机制),在重连风暴条件下显著放大故障,属于工程意义上的 bug,而非某一行代码写错。死连接实际吞噬的令牌比例上限约 81%,精确值需 `shutdown_count` 数据定论(§9)。

---

## 1. 关键代码路径(证据链)

### 1.1 令牌在 accept 成功后立即消耗,失败不返还

`_build/default/lib/esockd/src/esockd_acceptor.erl` L103-143, L187-193:

```erlang
accepting(info, {inet_async, LSock, Ref, {ok, Sock}}, ...) ->
    inet_db:register_socket(Sock, SockMod),
    esockd_server:inc_stats({Proto, ListenOn}, accepted, 1),   %% accepted 计数 +1
    ... 
        case esockd_connection_sup:start_connection(ConnSup, Sock, UpgradeFuns) of ...
    rate_limit(State);   %% <<<< 令牌在这里消耗

rate_limit(State = #state{conn_limiter = Limiter}) ->
    case esockd_limiter:consume(Limiter, 1) of
        {I, Pause} when I =< 0 ->
            {next_state, suspending, State, Pause};     %% 令牌耗尽,暂停 accept
        _ ->
            {keep_state, State, {next_event, internal, accept}}
    end.
```

令牌一旦消耗,后续无论 TLS 握手成功、还是 `ssl_upgrade_timeout` / `closed` 失败(见 `src/emqx_connection.erl` L276-283 的 `Transport:wait` → `exit_on_sock_error(timeout)` → `{shutdown, ssl_upgrade_timeout}`),**没有任何返还路径**。`esockd_limiter.erl` 只导出 `consume/1,2`,不存在 refund 接口。

### 1.2 限速暂停期间,listen socket 无人 accept

16 个 acceptor 共享同一个 bucket `{listener, ssl, {0,0,0,0,8883}}`(见 `esockd_listener_sup.erl` L227-236 `conn_rate_limiter/2`,以及 `esockd.erl` L290-293 将整数 `30` 解析为 `{30, 1}`)。令牌耗尽时所有 acceptor 都进入 `suspending` 状态,inet_drv 的 multi-accept 队列变空后,驱动层直接关闭 accept 事件监听——

`otp/erts/emulator/drivers/common/inet_drv.c` L11452-11460(`tcp_inet_input`,MULTI_ACCEPTING 分支):

```c
if (deq_multi_op(desc,&id,&req,&caller,&timeout,&monitor) != 0) { ... }
if (desc->multi_first == NULL) {
    sock_select(INETP(desc),FD_ACCEPT,0);          /* 关闭 accept 监听 */
    desc->inet.state = INET_STATE_LISTENING;        /* 恢复监听态 */
}
```

**这就是限速生效的底层机制:暂停期间 backlog 中已完成的握手(无论此时对端死活)不会被内核清理,只能等 acceptor 醒来后一个个取。**

### 1.3 backlog = 1024 与 30/s 的组合,把队列满时的排队时间推到 34~49 秒

队列持续满时(`ss -lnt` 的 Recv-Q 钉在 1024):

```
排队时间 W ≈ backlog / accept_rate = 1024 / 30 ≈ 34 秒
```

再叠加"平时每秒 6~9 个 `unknown_ca`/JWT 失败连接"——**这些失败连接同样消耗令牌**(它们 accept 成功后才在 TLS 握手或 MQTT 认证阶段失败),有效令牌只剩 21~24 个/s:

```
W ≈ 1024 / (30-6~9) ≈ 43~49 秒
```

注意:三次握手(SYN/ACK)由内核完成,连接进入 backlog 时客户端侧已经是 ESTABLISHED,客户端会立即发送 TLS ClientHello 并等待服务端响应——但服务端要等 34~49 秒后才 accept 它。**此数值是"队列持续满"前提下的排队时间上限;实际队列占用率随 SYN 率波动(见 §1.6),排队时间在 0~49s 之间起伏。**

### 1.4 客户端侧的时间线(内核行为,与代码相互印证)

```
t=0        客户端 SYN(挤进 backlog;挤不进的被 DROP 或走 syncookie 路径)
t≈RTT      内核完成三次握手,客户端 ESTABLISHED,立即发 ClientHello
t≈5~30s    客户端 SDK TLS/connect 超时(绝大多数 MQTT SDK 默认 5~30 秒),
           放弃连接
t≥排队时间  服务端 acceptor 才把它从 backlog 取出 → 多为死连接
```

**关键内核事实(复核确认):Linux 会把"已死"的连接照样从 accept 队列取出。** `inet_csk_accept()` 只做摘链(`reqsk_queue_remove`),不检查 `sk->sk_err`/`sk_state`;child socket 收到 FIN 或 RST 也不会被移出 accept 队列。内核清理队列中死连接的唯一时机是 listen socket 关闭(`inet_csk_listen_stop`)。"accept() 返回 ECONNABORTED"是 BSD/SVR4 的行为,Linux 上不存在。

内核源码依据(对照 `linux-3.10.0-1160.2.1.el7` 逐条核对):

- `inet_csk_accept()`(net/ipv4/inet_connection_sock.c:309-367):L339 `reqsk_queue_remove()` 摘链后直接返回 child,对其死活零检查;错误路径仅 `EINVAL/EAGAIN/EINTR`,不存在"跳过死连接取下一个"的逻辑。`reqsk_queue_remove()` 本身(include/net/request_sock.h:197-208)是纯链表摘头,全内核唯一调用者就是 accept。
- RST 处死链路 `tcp_v4_rcv → tcp_v4_do_rcv(tcp_ipv4.c:1487) → tcp_validate_incoming(tcp_input.c:5228) → tcp_reset(tcp_input.c:3934) → tcp_done(tcp.c:3051)`:置 `sk_err=ECONNRESET`、转 `TCP_CLOSE`,全程不触碰 accept 队列;FIN 路径 `tcp_fin`(tcp_input.c:3972)转 `TCP_CLOSE_WAIT`,同样不出队。
- 全内核写 accept 队列链表(`rskq_accept_head`)的代码仅三处:握手完成入队(`inet_csk_reqsk_queue_add`)、accept 出队、listen socket 关闭(`inet_csk_listen_stop`)。后者上方的内核注释(作者 ANK)自陈"对未 accept 的连接发 FIN 或 active reset,这两个变体现在都做不到"。
- 全 TCP 栈 grep `ECONNABORTED` 仅 2 处且均不在 accept 路径(tcp.c:2202 的 TCP repair 分支、af_inet.c:646 的 `connect()` 错误路径)。
- accept 出的死 fd 第一次 read 即返回 `ECONNRESET`(`tcp_recvmsg`,tcp.c:1674-1678)——正对应 esockd 侧"accept 成功扣令牌后,TLS 握手立即失败"。

被 accept 出来的死连接分三类(初版将 RST 一行误判为"不浪费令牌",已修正):

| 客户端放弃方式 | Linux 内核行为 | 服务端表现 | 令牌是否浪费 |
|---|---|---|---|
| 发 FIN(优雅关闭) | child 转 CLOSE_WAIT,不出队 | `accept()` 成功 → `ssl:handshake` 读到 EOF → `exit(normal)`,无日志 | **浪费** |
| 发 RST | `tcp_reset()` 置 sk_err=ECONNRESET、状态 TCP_CLOSE,不出队 | `accept()` 照样成功 → SSL 握手 I/O 失败 → `exit({shutdown, econnreset})`,无日志 | **浪费**。初版误写为"acceptor 收到 `{error, econnaborted}` 不浪费"——那是 BSD 行为;`esockd_acceptor.erl` L149-154 的 econnaborted 分支在 Linux 上是死代码 |
| 不再响应(设备掉电/静默放弃) | 队列中无任何动静 | accept 成功 → `ssl:handshake` 等满 `handshake_timeout=15s` 才超时 → `exit({shutdown, ssl_upgrade_timeout})`,无日志 | **浪费 + 拖 15 秒** |

**日志可见性说明**:closed/timeout/econnreset 等原子原因的连接失败不写日志、只进 `shutdown_count` 统计(`esockd_connection_sup.erl` L258-271 的 `connection_crashed/3`);只有复合原因(`{ssl_error,...}` 即 TLS alert 类)才写 error 日志。因此"日志中看不到死连接失败"是预期行为,不能作为死连接不存在的证据——这也是必须取 `shutdown_count` 数据的原因(§9)。

### 1.5 日志证据核验(修订时新增,修正初版强结论)

初版报告未对故障日志做定量分析。复核 `mqtt_log/emqx.log.8`、`emqx.log.9` 后发现三条与初版结论冲突的证据:

1. **unknown_ca 速率 16 小时完全平稳**:每分钟 312~381 条(约 5.8/s),横跨整个故障窗口,00:38 前后无任何变化。此类日志的语义是"客户端活着收到了服务端证书、验证失败、主动发回 unknown_ca alert"(`received CLIENT ALERT`)——死连接不可能产生(客户端已放弃就不会再发 alert)。因此**至少约 5.8/s(约 19%)的令牌喂给了确定活着的连接**,"30 个令牌全部喂给死连接"不成立。
2. **invalid_signature(JWT 过期)在故障窗口内持续出现**:每小时 150~900 条(约为故障前的 2~5 倍),每条都意味着一次完整建连(TCP → 排队 → accept → TLS 完整握手 → MQTT CONNECT → JWT 校验)走完全程。全协议栈的建连通道在"故障期"从未完全断绝。
3. **风暴窗口内存在 18~31s 的同客户端完整建连间隔**:按 ClientID 聚合 invalid_signature 事件的相邻间隔,00:38~10:38 窗口内 30 个间隔中有 8 个 < 34s(最短 18s)。若稳态排队 34~49s,同客户端相邻两次完整建连(还需加上 TLS+CONNECT 处理与客户端退避时间)物理上不可能小于 34s。18s 的间隔说明当时端到端建连延迟 < 18s——**"backlog 恒满 1024、排队时间恒定 34~49s 的自持续死锁稳态"被否定**。

### 1.6 故障的真实形态:临界波动而非刚性死锁

初版的"死锁稳态"假设 SYN 率持续远大于 30/s。但客户端 connect 超时后会退避重试:10 万客户端哪怕退避到 5 分钟一次,平均 SYN 率仍有约 333/s,大于 30/s;可一旦指数退避拉长到 10 分钟以上,SYN 率就落到 30/s 临界点附近——**backlog 占用率随之波动:队列满时排队时间飙到数十秒(死连接浪费严重),队列空时排队接近 0(建连能走通)**。invalid_signature 重试间隔呈"最短 18s、中位数 108s、最长 1 小时+"的宽分布,正是这种波动的直接体现。

死连接浪费令牌的机制真实存在,但它是故障的**放大器**而非全部原因;有效建连速率被压到多低,取决于死连接在 30/s 名额中的实际占比——该比例上限约 81%(扣除 unknown_ca 类活连接的约 19%),精确值必须由 `shutdown_count` 数据(closed/ssl_upgrade_timeout/econnreset 计数)定论。

---

## 2. 逐条解释现场观察到的现象

| 现象 | 解释 |
|---|---|
| telnet 8883 不通/极慢,SYN 被 DROP | backlog 满 + Linux 默认 `net.ipv4.tcp_abort_on_overflow=0` 静默丢弃 SYN,客户端靠 1s/2s/4s 指数退避重传碰运气。**注意**:若 syncookies=1(Linux 默认),SYN 并不会被丢而是回 cookie SYN-ACK,客户端 connect() 成功、第三次握手的 ACK 在队列满时被丢,体验同样是"telnet 极慢"——需抓包确认属于哪种(§5.3) |
| Accept 队列(1024)已满 | SYN 率高于 30/s 的 accept 周转率,队列持续堆积;排队期间客户端大量超时放弃,腾出的名额又被新的(未来会死的)连接占据 |
| 预期"30/s 慢慢恢复"但 10 小时未完成 | 30/s 是 accept 速率;队列占用率波动,高峰期排队数十秒导致被 accept 的连接大量已死(TLS 超时短于排队时间的客户端全部阵亡),令牌被死连接白白消耗;`accepted` 计数照常增长,但在线连接数恢复远慢于预期。有效建连被压低的幅度需 shutdown_count 定论 |
| 部分客户端因 MQTT keepalive 被服务端断开 | **"服务端认为已建立、客户端已放弃"的错位连接**:部分客户端 connect 超时返回失败但 socket 未彻底关闭(或 TLS 超时晚于排队时间),服务端最终完成 accept + TLS + MQTT CONNECT,而客户端应用层不再收发任何数据 → `recv_oct` 不变 → `emqx_keepalive:check/2`(`src/emqx_keepalive.erl` L66-74)连续两次 StatVal 不变 → `{error, timeout}` → `emqx_channel.erl` L1114-1121 发 DISCONNECT 断开。**断开后客户端又重连,继续给风暴供血**。另需排查另一来源:网络分区导致的服务端僵尸 TCP(见下一行) |
| 10 小时后连接数比之前少 10 万(初始只掉线 2 万) | 多因素叠加:① 若掉线源于客户端侧网络分区,服务端 TCP 连接并不会立刻消失(TCP keepalive 默认 2 小时,靠 MQTT keepalive 渐进清理),僵尸陆续被踢、重连又建不上,持续净流失;② 风暴期间**所有**客户端的日常重连(网络抖动、keepalive 踢僵尸、会话异常等)全部受阻;③ SYN 风暴可能打挂中间网络设备(LB/防火墙/NAT 会话表),导致更多连接二次掉线——这是 EMQX 日志完全不可见的层面;④ 客户端指数退避拉长了恢复时间轴 |
| 平时每秒 6~9 个 unknown_ca/JWT 失败没出问题 | 平时 SYN 率低、backlog 不满、排队时间≈0,accept 到的都是活连接;失败连接只是浪费 20~30% 令牌,无感知 |

---

## 3. 这是不是我们的 bug?

**是,属于设计缺陷(工程意义上的 bug),不是某一行代码写错。** 三个组件单独看都"按设计工作",组合起来却违背了设计意图:

1. **计费点错位**:`esockd_acceptor` 在 accept 时刻计费,而连接的死活要等到 TLS 握手/MQTT CONNECT 才知道。风暴高峰期无效连接挤占大量配额,且无返还机制。限速器本意是"保护自己不被打垮",实际效果却包含"把宝贵的 accept 名额送给早已死去的连接"。
2. **backlog 反向放大**:直觉上 backlog 越大越好,但在限速场景下 **backlog 是"死连接蓄水池"——backlog 越大,排队时间越长,客户端在排队中死亡的比例越高**。1024/30 ≈ 34s 落在不少客户端 SDK 的超时区间内,这是一个不利的默认组合。
3. **无自适应恢复能力**:风暴期间没有检测"accept 计数增长 vs 在线连接数不涨"的背离并作出反应(放宽限速/清理 backlog)的机制。

同时必须指出:本缺陷是故障的**放大器**而非唯一成因。客户端重试策略、(可能的)服务端僵尸 TCP、中间网络设备行为共同决定了最终 10 万的损失规模(见 §1.6 与 §9)。

责任归属:esockd 限速模型(EMQX 维护的依赖)+ 默认配置组合共同导致;EMQX 应用层(emqx_connection/channel)行为正确。

---

## 4. 修复与缓解建议(按见效速度排序)

1. **调小 backlog(立竿见影,改配置即可)**:`listener.ssl.external.backlog = 128` 或更小。排队时间降至 128/30 ≈ 4s,远小于客户端超时,死连接比例骤降。这在限速器存在时是正确方向,尽管与"大 backlog 抗突发"的直觉相反。
2. **令牌返还机制(根治,需改 esockd)**:给 `esockd_limiter` 增加 refund 接口,连接以 `timeout / closed / econnreset` 等"客户端未完成握手即消失"的原因失败时返还令牌。注意:`unknown_ca`/JWT 拒绝类失败**不应**返还(否则扫描器可用无效证书绕过限速)。
3. **客户端侧配合**:指数退避 + 随机抖动,把瞬时 SYN 率压到接近 30/s;connect 超时后**确保关闭 socket**(避免错位连接被 keepalive 踢掉后再次触发重连)。
4. **风暴自适应(可选,需改 esockd/EMQX)**:监控 `accepted` 增速与在线连接数增速的长期背离,超过阈值时临时放宽 `max_conn_rate` 或主动 flush backlog(短暂暂停监听再恢复,内核会 RST 掉积压的死连接)。
5. **应急恢复手段**:重新启动监听器(如 `emqx ctl listeners restart ...`)或重启节点——清空 backlog(死连接池)后,客户端重连重新竞争,只要瞬时风暴被吹散即可回到正常轨道。

---

## 5. 现场验证方法(量化并定论本诊断)

1. `emqx ctl listeners` / Dashboard:
   - `accepted` 速率与在线连接数增速的**背离幅度**——直接量化令牌被死连接浪费的规模(日志无法给出,因 closed/timeout/econnreset 不写日志,见 §1.4);
   - `shutdown_count` 中 `ssl_upgrade_timeout` / `closed` / `econnreset` 的计数(分别对应静默/FIN/RST 三类死连接,§1.4)。这是区分"死连接浪费主导"与"其他因素主导"的决定性数据。
2. `ss -lnt sport = :8883`:Recv-Q 高峰期持续处于 1024(backlog 满的直接证据);若长期观测到 0~1024 之间波动,则印证 §1.6 的临界波动模型。
3. 抓包(tcpdump port 8883):
   - 大量 SYN 重传(1s/2s/4s 间隔)即 SYN 被丢弃的客户端侧表现;若 SYN-ACK 有回但 ACK 后无任何响应,则说明 syncookies 生效、拥塞发生在三次握手完成阶段;
   - 被成功 accept 的连接:ClientHello 之后服务端长时间(数十秒)无握手响应,随后对端 FIN/RST 或 15s 后服务端发 alert 关闭;
   - 部分连接服务端完成了完整 TLS + MQTT CONNECT 且发出 CONNACK,但之后客户端应用层零流量,直至 keepalive 到期服务端发 DISCONNECT(错位连接证据)。
4. 事后统计:对比故障窗口内 `accepted` 累计增量与实际新增在线连接数,差值即被浪费的建连名额规模(含死连接与坏配置客户端两部分;日志分析给出其上限约 81%,见 §1.5/§1.6)。

---

## 6. 关键文件索引

| 文件 | 角色 |
|---|---|
| `_build/default/lib/esockd/src/esockd_limiter.erl` | 令牌桶(ETS + gen_server,无 refund) |
| `_build/default/lib/esockd/src/esockd_acceptor.erl` | acceptor 状态机,accept 后 consume,耗尽进入 suspending |
| `_build/default/lib/esockd/src/esockd_listener_sup.erl` | limiter 创建,`{30,1}` bucket |
| `_build/default/lib/esockd/src/esockd_connection_sup.erl` | 连接 sup(计 max_connections);`connection_crashed/3` 决定失败是否写日志:closed/timeout/econnreset 原子原因只进 shutdown_count 不写日志,`{ssl_error,...}` 复合原因才写 error 日志(§1.4 日志可见性的出处) |
| `_build/default/lib/esockd/src/esockd_transport.erl` | `wait/1` 收 `{sock_ready}` 后执行 ssl_upgrade;`handshake_timeout` 由此传入 `ssl:handshake/3` |
| `src/emqx_connection.erl` | 连接进程:`init/4` 中 `Transport:wait` 做 TLS 握手;`ssl_upgrade_timeout` 退出 |
| `src/emqx_channel.erl` | keepalive 超时 → DISCONNECT |
| `src/emqx_keepalive.erl` | `check/2`:StatVal 连续两次不变即 `{error, timeout}` |
| `otp/erts/emulator/drivers/common/inet_drv.c` | 驱动层 multi-accept 队列;L11457-11460 暂停时关闭 FD_ACCEPT |
| `otp/erts/preloaded/src/prim_inet.erl` | `async_accept/2`(标准实现,无定制问题) |

---

## 8. 修复验证补充(2026-08-25,跟进 §4 建议 #2 的实施)

### 8.1 验证:死连接的探测只需 `peername`,无需额外探针

用与 esockd_acceptor 相同的 `prim_inet:async_accept` 路径(不经 gen_tcp:accept 的 accept_opts),在 macOS(OTP 27)、alpine:3.21(OTP 26、kernel 6.8)、ubuntu:22.04(OTP 24.2.1、kernel 6.8)三处实测 **peer 在 accept 前后 RST 掉的 accepted socket**:

| 平台 | `inet:peername` | `getsockopt(SO_ERROR)` | `recv(0, 0)` |
|---|---|---|---|
| macOS(Darwin 25) | `{error, einval}` | 54(ECONNRESET) | `{error, closed}` |
| Linux 6.8(alpine/ubuntu) | `{error, enotconn}` | 104(ECONNRESET) | `{error, closed}` |
| FIN 关闭(两平台) | `{ok, Peer}`(无法区分,失败开放) | 0 | `{error, closed}` |

两个关键结论:

1. **`inet:peername` 在 macOS 与 Linux 上都探测得到 RST 死连接,只是 errno 不同**(einval vs enotconn)。此前担心的"Linux 的 peername 与 macOS 行为不同"确实存在——但区别只是错误码,不是"能否探测"。内核源码核对(torvalds/linux v3.10 与 v6.8 的 `net/ipv4/af_inet.c` 的 `inet_getname`)确认两代内核都含 `((1 << sk->sk_state) & (TCPF_CLOSE | TCPF_SYN_SENT)) → -ENOTCONN` 检查,而 RST 死连接经 `tcp_reset → tcp_done` 置为 `TCP_CLOSE`——**因此客户环境的 CentOS 7(kernel 3.10)同样返回 ENOTCONN**,peername 探测在客户内核上同样有效。
2. 原修复实现为此额外加的 `is_sock_alive`(peername + 平台相关 SO_ERROR 常量)是多余的:**它引入了每次 accept 两次额外系统调用**;且其 BSD/macOS 常量 `{raw, 16#FFFF, 4, 4}` 是 Linux 的 SO_ERROR=4,macOS 实际是 `SO_ERROR=0x1007`(4103),在 macOS 上该 getsockopt 恒返回 `{ok, []}` 走 fail-open 分支,实为死代码——macOS 上的检测完全靠 peername 前置检查,与"只用 start_connection 内部的 peername"效果相同。

### 8.2 最终修复形态(已实现,附 CT 用例)

- **删除 `is_sock_alive/1` 及其 SO_ERROR 平台常量**(消除额外系统调用);
- 依赖 `esockd_connection_sup:start_connection` 内部已有的 `esockd_transport:peername`(原代码就有):死连接 → `{error, enotconn}`(Linux)/`{error, einval}`(macOS)→ acceptor 静默关闭,**不消耗连接速率令牌**;
- `rate_limit/2` 改为按结果消费:仅当真正启动了连接进程(`{ok,_Pid}`)才 consume;`einval/enotconn` 不消费;`maxlimit/forbidden` 等其他拒绝仍消费(保持限速器对拒绝路径的节流作用,与修复前一致);
- 新增 `discarded` 统计(`esockd_listener_sup` init,acceptor 在 einval/enotconn 路径 inc),用于观测"accept 时对端已消失"的死连接数量(呼应 §9.1 对量化数据的需求);
- `test/esockd_acceptor_SUITE.erl`:确定性复现"acceptor 挂起期间连接在 backlog 中被 RST"的场景,断言死连接不消耗令牌、`accepted+1`、`discarded+1`,且后续活连接不被节流;macOS(OTP 27)与 Linux(OTP 26,alpine 容器)上 CT 3/3 通过,ubuntu(OTP 24.2.1)手工端到端结果一致。

> 注意:死连接探测只覆盖 RST 类(FIN 类在 accept 时刻无法与活连接区分,保持 fail-open,见 §1.4 表格)。另外 `esockd_dtls_acceptor.erl` 仍保留修复前"无条件 consume"的模式,DTLS 监听器存在同样的令牌浪费问题,未在本轮改动范围内,建议后续按相同思路处理并做 DTLS 专项验证。

---

## 9. 遗留疑问(建议工程师复核)

1. **(决定性)取回故障窗口的 `shutdown_count`**:`emqx ctl listeners` 或 Dashboard 的 closed / ssl_upgrade_timeout / econnreset 计数。这三类原子原因不写日志、只进计数器(§1.4),是量化"死连接吞掉多少令牌"的唯一直接证据,可一锤定音地区分"死连接浪费主导"与"其他因素主导"。
2. **取回 accepted 累计增量与在线连接数增量**:两者之差即被浪费的建连名额规模。
3. **syncookies 是否启用**(`net.ipv4.tcp_syncookies`,Linux 默认 1):决定"SYN 被 DROP"的真实机制(SYN 直接丢弃 vs cookie 后 ACK 被丢),影响排障方向。
4. **00:38 批量掉线的根因**:客户端侧网络分区/中间设备故障,还是服务端/EMQX 自身?若为前者,服务端会留有大量僵尸 TCP(TCP keepalive 默认 2 小时,靠 MQTT keepalive 渐进清理),这本身就能解释相当一部分"连接数持续净流失",与令牌浪费无关。
5. 现场是否启用了 `proxy_protocol`?若启用,proxy 超时(`proxy_protocol_timeout` 默认 3s)会先于 ssl 握手失败,不影响结论但影响 shutdown_count 的分布。
6. 客户端 SDK 的 connect/TLS 超时具体值与重试策略(决定"排队中死亡"的比例与风暴持续时间),建议向客户确认。
7. 风暴期间 BEAM 是否出现过调度器饱和?若调度器饱和,acceptor 恢复可能晚于令牌补充,排队时间会比理论值更长。
8. 中间网络设备(LB/防火墙/NAT)在 SYN 风暴期间的会话表/CPU 状态——"2 万滚成 10 万"的放大可能主要发生在这里,EMQX 日志完全不可见。
