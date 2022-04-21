---
title: 如何写一个单机支持200wQPS的STUN服务器
date: 2022-03-28 17:45:48
tags: [rust,udp,stun]
---

目前开源的stun服务器有c语言的实现coturn、和cpp语言实现stunserver，他们实现了完整的stun协议，但是他们都是单线程的服务。在请求不高的情况下，他们都能很多的工作，但是在某些实时要求非常好的场景，这些单线程的服务器马上就到瓶颈了。 

stun服务器的逻辑非常简单，收一条udp消息，把它解码为stun的message，如果解码成功了，往请求方返回一个stun的message消息。再无其他。



