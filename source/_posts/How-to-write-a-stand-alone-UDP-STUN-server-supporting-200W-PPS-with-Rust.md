---
title: 用rust实现单机支持200万PPS的STUN服务器
date: 2022-03-28 17:45:48
tags: [rust,udp,stun]
---

目前开源的stun服务器有c语言的实现coturn、和cpp语言实现stunserver，他们实现了完整的stun协议，但是他们都是单线程的服务。在请求不高的情况下，他们都能很好的工作，但是在某些并发性,实时性要求非常高的场景，这些单线程的服务器马上就到瓶颈了。 

stun服务器的逻辑非常简单，收一条udp消息，把它解码为stun的message，如果解码成功了，取到他的source ip port 再往请求方返回一个stun的message消息。再无其他。

在直播的p2p的场景下，当一个用户打开某个直播间，他会要求马上和12用户建立p2p的连接，和这12个用户建连的过程是ICE的过程，是并行的
那么可以认为一个用户会有12QPS，假设 当一个直播间突然有100w用户的时候，这100w用户同时寻找其中的12个用户建连，那么对stun就会有1200w QPS，好在直播间的进入是一个渐进的过程，并且一个用户连满了12 用户之后 就并不会再建连请求stun，所以真实的场景没有那么夸张，但是某些情况下，同个直播间有可能会有1000w人，如何支撑1000w人的直播p2p成功，对服务端的抗压能力是个很大的考验。
## stun 协议

### stun message
所有的STUN meesage 用大数编码的二进制数据，以20字节的header开头，接着跟着0个或者多个属性（Attribute），
STUN header 包含消息类型、magic cookie、 transaction ID
和 message length

![](../image/stunheader.png)

message type : request 、success failure response、indication 

magic cookie : fixed value 0x2112A442

transation ID : uniquely identify STUN transactions.

当然协议解析的工作我们不用亲自做，使用已有的开源库即可 github.com/webrtc-rs/stun;

利用stun的第三方库我们可以很快的写出服务端解析请求数据包成为stun message,如果解析成功我们会得到一个Message的实例，如果不成功我们返回None;
```rust
use std::net::SocketAddr;
use stun::message::*;
use stun::xoraddr::*;
use nix::sys::socket::SockAddr;

fn process_stun_request(src_addr: SockAddr, buf: Vec<u8>) -> Option<Message> {
    let mut msg = Message::new();
    msg.raw = buf;
    if msg.decode().is_err() {
        return None;
    }
    if msg.typ != BINDING_REQUEST {
        return None;
    }
    match src_addr.to_string().parse::<SocketAddr>() {
        Err(_) => return None,
        Ok(src_skt_addr) => {
            let xoraddr = XorMappedAddress {
                ip: src_skt_addr.ip(),
                port: src_skt_addr.port(),
            };
            msg.typ = BINDING_SUCCESS;
            msg.write_header();
            match xoraddr.add_to(&mut msg) {
                Err(_) => None,
                Ok(_) => Some(msg),
            }
        }
    }
}
```


nix库封装了libc的ffi调用函数，提供了非常友好的且Safe的*nix系统调用API,系统调用非常方便。我们需要recvmsg 和recvmmsg 以及sendmsg 和sendmmsg都通过该库来实现。 

我们先写个单线程的stun服务器,方面说明，我们对所有的错误进行了忽略
添加引入包
```rust
use nix::sys::socket::{
    self, sockopt, AddressFamily, InetAddr, MsgFlags, SockFlag, SockType,
};
```

```rust
fn main() {
    let inet_addr = InetAddr::new(IpAddr::new_v4(0, 0, 0, 0), 3478);
    run_single_thread(inet_addr)
}

pub fn run_single_thread(inet_addr: InetAddr) {
    let skt_addr = SockAddr::new_inet(inet_addr);
    let skt = socket::socket(
        AddressFamily::Inet,
        SockType::Datagram,
        SockFlag::empty(),
        None,
    )
    .unwrap();
    socket::bind(skt, &skt_addr).unwrap();
    let mut buf = [0u8; 50];
    loop {
        match socket::recvfrom(skt, &mut buf) {
            Err(_) => {}
            Ok((len, src_addr_op)) => match src_addr_op {
                None => {}
                Some(src_addr) => {
                    if let Some(msg) = process_stun_request(src_addr, buf[..len].to_vec()) {
                        _ = socket::sendto(skt, &msg.raw, &src_addr, MsgFlags::MSG_DONTWAIT);
                    }
                }
            },
        }
    }
}
```


## 多线程
### 网卡多队列

起初，网卡只有一个单一的读写队列用来在内核和硬件之间收发数据包，这样的设计有个缺陷，数据包的传送能力受限于一个CPU的处理能力。为了支持多核的系统，网卡都开始支持多个读写队列：每个RX队列绑定系统中的一个CPU,这样网卡就能利用起来系统中所有的核，通常，数据包根据一定的hash算法把数据包分配给确定的队列，通常根据（src ip、dst ip、src port 、dst port）四元组来计算哈希值，这保证了对于一个数据流的数据发送和接受都是在同一个RX队列里面，数据包的乱序也不会发生。

![](../image/multiqueue.png)


### SO_REUSEPORT
在Linux kernel 3.9带来了SO_REUSEPORT特性， 这是一个socket的选项，设置了这个选项，操作系统允许多个进程或者线程绑定一个相同的PORT用于提高服务器的性能，它包含了一下特性:
- 允许多个socket bind 同一个TCP/UDP 端口
- 每个线程拥有自己的socket
- socket 没有锁竞争
- 内核层面实现了负载均衡
- 安全层面监听同一个端口的socket只能位于同一个用户下

在代码层面我们做两处改动
1. main函数改成如下

```rust
fn main() {
    let inet_addr = InetAddr::new(IpAddr::new_v4(0, 0, 0, 0), 3478);
    let cpu_num = num_cpus::get();
    let mut i = 1;
    while i <= cpu_num {
        let inet_addr_n = inet_addr.clone();
        thread::spawn(move || run_reuse_port(inet_addr_n));
        i += 1;
    }
    run_reuse_port(inet_addr)
}
```

2. socket 添加 ReusePort 选项 

```rust
pub fn run_reuse_port(inet_addr: InetAddr) {
    ...
    socket::setsockopt(skt, sockopt::ReusePort, &true).unwrap();
    socket::bind(skt, &skt_addr).unwrap();
    ...
}
```


## Linux独有的API
通过上面的步骤，我们已经将单线程的服务改成了多线程，极大的提高了服务器的性能，后面我们继续使用linux的独有的api,sendmmsg和recvmmsg 再把服务器性能提高30%:

1. 在一个socket上接受和发送多条消息，recvmmsg()系统调用是recvmsg的扩展，他允许调用着通过一次系统调用接受多条消息，支持设置超时时间和每批次接受消息的数量。

2. sendmmsg()也是一样的原理通过减少系统调用的次数来降低cpu的使用率，从而提高应用的性能

添加引入包
```rust
#[cfg(any(target_os = "linux"))]
use nix::sys::socket::{ RecvMmsgData, SendMmsgData};
```

```rust
#[cfg(any(target_os = "linux"))]
pub fn run_reuse_port_recv_send_mmsg(inet_addr: InetAddr) {
    let skt_addr = SockAddr::new_inet(inet_addr);
    let skt = socket::socket(
        AddressFamily::Inet,
        SockType::Datagram,
        SockFlag::empty(),
        None,
    )
    .unwrap();
    socket::setsockopt(skt, sockopt::ReusePort, &true).unwrap();
    socket::bind(skt, &skt_addr).unwrap();
    loop {
        let mut recv_msg_list = std::collections::LinkedList::new();
        let mut receive_buffers = [[0u8; 50]; 1000];
        let iovs: Vec<_> = receive_buffers
            .iter_mut()
            .map(|buf| [IoVec::from_mut_slice(&mut buf[..])])
            .collect();
        for iov in &iovs {
            recv_msg_list.push_back(RecvMmsgData {
                iov,
                cmsg_buffer: None,
            })
        }

        let time_spec = TimeSpec::from_duration(Duration::from_micros(10));
        let resp_result =
            socket::recvmmsg(skt, &mut recv_msg_list, MsgFlags::empty(), Some(time_spec));

        match resp_result {
            Err(_) => {}
            Ok(resp) => {
                let mut msgs = Vec::new();
                let mut src_addr_vec = Vec::new();

                for recv_msg in resp {
                    src_addr_vec.push(recv_msg.address)
                }
                for (buf, src_addr_opt) in zip(receive_buffers, src_addr_vec) {
                    match src_addr_opt {
                        None => {}
                        Some(src_addr) => {
                            if let Some(msg) = process_stun_request(src_addr, buf.to_vec()) {
                                _ = socket::sendto(
                                    skt,
                                    &msg.raw,
                                    &src_addr,
                                    MsgFlags::MSG_DONTWAIT,
                                );
                            }
                        }
                    }
                }

                let mut send_msg_list = std::collections::LinkedList::new();
                let send_data: Vec<_> = msgs
                    .iter()
                    .map(|(buf, src_addr)| {
                        let iov = [IoVec::from_slice(&buf[..])];
                        let addr = *src_addr;
                        (iov, addr)
                    })
                    .collect();

                for (iov, addrx) in send_data {
                    let send_msg = SendMmsgData {
                        iov,
                        cmsgs: &[],
                        addr: addrx,
                        _lt: Default::default(),
                    };
                    send_msg_list.push_back(send_msg);
                }

                _ = socket::sendmmsg(skt, send_msg_list.iter(), MsgFlags::MSG_DONTWAIT);
            }
        }
    }
}
```

## 总结
1. 使用多线程和网卡多队列绑核的特性提高性能充分利用起来网卡多队列和linux系统本省具有的能力
2. 使用linux sendmmsg 和recvmmsg 可以提高很大的性能，批量收取的消息量Vlen需要根据各个业务的时机情况去设置，并且加上合理的超时时间，这才能发挥这两个api的最大功效
3. rust是一门性能非常优秀，开发工具十分完善，语法设计十分优雅的语言，值得投入。 
