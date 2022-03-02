---
title: How To Build A Golang ORM Tool
date: 2022-02-13 21:24:48
tags:
---
为了提高开发效率和质量，我们常常需要ORM来帮助我们快速的实现持久层增删改查API的实现，目前go语言实现的ORM有很多种，他们都有自己的优劣点，有的实现简单，有的功能复杂，有的API十分优雅。在使用了多个类似的工具之后，总是会发现某些点无法满足解决我们生产环境中碰到的实际问题。所有有必要自己实现一款满足我们自定义开发的ORM。

## 为什么需要ORM

### 直接使用database/sql的痛点
首先看看用database/sql如何查询数据库
我们用user来做例子：
表结构如下：
```SQL
CREATE TABLE `user` (
  `id` int(10) unsigned NOT NULL AUTO_INCREMENT COMMENT 'id字段',
  `name` varchar(100) NOT NULL COMMENT '名称',
  `age` int(11) NOT NULL DEFAULT '0' COMMENT '年龄',
  `ctime` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
  `mtime` datetime NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
  PRIMARY KEY (`id`),
) ENGINE=InnoDB  DEFAULT CHARSET=utf8mb4
```
首先我们要写出和表结构对应的结构体User,如果你足够勤奋和努力，相应的json tag 和注释都可以写上

```go
type User struct {
	Id    int64     `json:"id"`    // id字段
	Name  string    `json:"name"`  // 名称
	Age   int64     `json:"age"`   // 年龄
	Ctime time.Time `json:"ctime"` // 创建时间
	Mtime time.Time `json:"mtime"` // 更新时间
}
```
定义好结构体，我们写一个查询年龄在20以下且按照id字段倒序排序的20用户的go代码

```go
func FindUser() ([]*User, error) {
	rows, err := db.QueryContext(ctx, "SELECT SELECT `id`,`name`,`age`,`ctime`,`mtime` FROM user WHERE `age`<? ORDER BY `id` DESC LIMIT 20 ", 20)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	result := []*User{}
	for rows.Next() {
		a := &User{}
		if err := rows.Scan(&a.Id, &a.Name, &a.Age, &a.Ctime, &a.Mtime); err != nil {
			return nil, err
		}
		result = append(result, a)
	}
	if rows.Err() != nil {
		return nil, rows.Err()
	}
	return result, nil
}

```
当我们写少量这样的代码的时候我们可能还觉得轻松，但是当你业务工期排的很紧，并且要写大量的定制化查询的时候，这样的重复代码会越来越多
上面的的代码我们发现有这么几个问题
1. sql 语句是硬编码在程序里面的，当我需要增加查询条件的时候我需要另外再写一个方法，很不灵活
2. 下面的代码都是一样重复的，不管sql语句是怎么样的
3. 我们发现第一行sql语句和rows.Scan那行，写的枯燥层度是和表字段的多少成正比的，如果一个表有50个字段或者100个字段，手写是非常乏味的
4. 在开发过程中，rows.Close() 和 row.Err()忘记写是常见的错误

我们在看以下插入的写法

```go
func InsertUser(u *User) error {
	res, err := db.ExecContext(
		ctx,
		"INSERT INTO `user` (`id`,`name`,`age`,`ctime`,`mtime`) VALUE(?,?,?,?,?)",
		u.Id, u.Name, u.Age, u.Ctime, u.Mtime,
	)
	if err != nil {
		return err
	}
	id, err := res.LastInsertId()
	if err != nil {
		return err
	}
	u.Id = id
	return nil
}
```
同样的问题
1. ExecContext 中写表字段和接口字段的枯燥层度和表字段数量是成正比的



### 提高开发效率

很显然写上面的那种代码是很耗费时间的，如果上面的代码能够自动生成
那么那将会极大的提高生产质量和减少human error的发生
### 减少开发者的心智负担，可以把精力聚焦于业务逻辑的设计上,和困难点攻坚上

如果一个开发人员把大量的时间花在这些代码上，那么他其实是在浪费自己的时间，不管在工作中还是在个人项目中，应该把重点花在架构设计，业务逻辑设计，困难点攻坚上面，去探索和开拓自己没有经验的领域，这块Dao层的代码最好在10分钟内完成。

## ORM的核心组成

明白了上面的痛点，和为了开发工作更舒服，我们尝试着自己去开发一个ORM，核心的地方在于两个方面：
1. sql语句非硬编码，可以通过某种构造器帮助我构建sql语句
2. 从数据库返回的结构可以自动mapping到我的结构体中

我们尝试做个简略版的

### sqlbuilder的实现

### scanner的实现

## 自动生成

## 不止ORM

### GRPC API

### GRPC Serice Implement

