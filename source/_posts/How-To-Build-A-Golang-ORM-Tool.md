---
title: 如何用go实现一个ORM
date: 2022-03-03 21:24:48
tags: [golang,orm,grpc,proto]
---
为了提高开发效率和质量，我们常常需要ORM来帮助我们快速实现持久层增删改查API，目前go语言实现的ORM有很多种，他们都有自己的优劣点，有的实现简单，有的功能复杂，有的API十分优雅。在使用了多个类似的工具之后，总是会发现某些点无法满足解决我们生产环境中碰到的实际问题，比如没有集成公司内部的监控，Tracer组件，没有database层的超时设置，没有熔断等，所以有必要公司自己内部实现一款满足我们可自定义开发的ORM。

## 为什么需要ORM

### 直接使用database/sql的痛点
首先看看用database/sql如何查询数据库
我们用user来做例子，一般的工作流程是先做技术方案，其中排在比较前面的是数据库表的设计，大部分公司应该有严格的数据库权限控制，不会给线上程序使用比较危险的操作权限，比如创建删除数据库，表，删除数据等。
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
首先我们要写出和表结构对应的结构体User,如果你足够勤奋和努力，相应的json tag 和注释都可以写上，这个过程无聊且重复，因为在设计表结构的时候你已经写过一遍了。 

```go
type User struct {
	Id    int64     `json:"id"`    // id字段
	Name  string    `json:"name"`  // 名称
	Age   int64     `json:"age"`   // 年龄
	Ctime time.Time `json:"ctime"` // 创建时间
	Mtime time.Time `json:"mtime"` // 更新时间
}
```
定义好结构体，我们写一个查询年龄在20以下且按照id字段顺序排序的前20名用户的 go代码

```go
func FindUsers() ([]*User, error) {
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
当我们写少量这样的代码的时候我们可能还觉得轻松，但是当你业务工期排的很紧，并且要写大量的定制化查询的时候，这样的重复代码会越来越多。
上面的的代码我们发现有这么几个问题：
1. SQL 语句是硬编码在程序里面的，当我需要增加查询条件的时候我需要另外再写一个方法，整个方法需要拷贝一份，很不灵活。
2. 第2行下面的代码都是一样重复的，不管sql语句后面的条件是怎么样的。
3. 我们发现第1行SQL语句编写和`rows.Scan()`那行，写的枯燥层度是和表字段的数量成正比的，如果一个表有50个字段或者100个字段，手写是非常乏味的。
4. 在开发过程中`rows.Close()` 和 `rows.Err()`忘记写是常见的错误。

我们再看一下插入的写法：

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
1. `ExecContext`方法中书写表字段名和结构体字段名的枯燥层度和字段数量是成正比的


### 开发效率很低

很显然写上面的那种代码是很耗费时间的，因为手误容易写错，无可避免要增加自测的时间。如果上面的代码能够自动生成，那么那将会极大的提高生产质量和效率并且减少human error的发生。
### 心智负担很重 

如果一个开发人员把大量的时间花在这些代码上，那么他其实是在浪费自己的时间，不管在工作中还是在个人项目中，应该把重点花在架构设计，业务逻辑设计，困难点攻坚上面，去探索和开拓自己没有经验的领域，这块Dao层的代码最好在10分钟内完成。

## ORM的核心组成

明白了上面的痛点，和为了开发工作更舒服，我们尝试着自己去开发一个ORM，核心的地方在于两个方面：
1. SQL语句要非硬编码，通过某种链式调用构造器帮助我构建SQL语句。
2. 从数据库返回的数据可以自动映射赋值到结构体中。

![](/image/sqlbuilder-scanner.png)

我们尝试做个简略版的查询语句构造器

### SQL SelectBuilder的实现
```go

type SelectBuilder struct {
	builder   *strings.Builder
	column    []string
	tableName string
	where     []func(s *SelectBuilder)
	args      []interface{}
	orderby   string
	offset    *int64
	limit     *int64
}

func (s *SelectBuilder) Select(field ...string) *SelectBuilder {
	s.column = append(s.column, field...)
	return s
}
func GT(field string, arg interface{}) func(s *SelectBuilder) {
	return func(s *SelectBuilder) {
		s.builder.WriteString("`" + field + "`" + " > ?")
		s.args = append(s.args, arg)
	}

}
func (s *SelectBuilder) From(name string) *SelectBuilder {
	s.tabelName = name
	return s
}
func (s *SelectBuilder) Where(f ...func(s *SelectBuilder)) *SelectBuilder {
	s.where = append(s.where, f...)
	return s
}
func (s *SelectBuilder) OrderBy(field string) *SelectBuilder {
	s.orderby = field
	return s
}
func (s *SelectBuilder) Limit(offset, limit int64) *SelectBuilder {
	s.offset = &offset
	s.limit = &limit
	return s
}
func (s *SelectBuilder) Query() (string, []interface{}) {
	s.builder.WriteString("SELECT ")
	for k, v := range s.column {
		if k > 0 {
			s.builder.WriteString(",")
		}
		s.builder.WriteString("`" + v + "`")
	}
	s.builder.WriteString(" FROM ")
	s.builder.WriteString("`" + s.tableName + "` ")
	if len(s.where) > 0 {
		s.builder.WriteString("WHERE ")
		for k, f := range s.where {
			if k > 0 {
				s.builder.WriteString(" AND ")
			}
			f(s)
		}
	}
	if s.orderby != "" {
		s.builder.WriteString(" ORDER BY " + s.orderby)
	}
	if s.limit != nil {
		s.builder.WriteString(" LIMIT ")
		s.builder.WriteString(strconv.FormatInt(*s.limit, 10))
	}
	if s.offset != nil {
		s.builder.WriteString(" OFFSET ")
		s.builder.WriteString(strconv.FormatInt(*s.limit, 10))
	}
	return s.builder.String(), s.args
}

```
1. 通过结构体上的方法调用返回自身，使其具有链式调用能力，并通过方法调用设置结构体中的值。
```go
func(s *SelectBuilder)Select(field ...string)*SelectBuilder{
	s.column = append(s.column, field...)
	return s 
}
```

2. `SelectBuilder` 包含性能较高的`strings.Builder` 来拼接字符串。
3. `Query()`方法使用`SelectBuilder`自身已经赋值的元素构造，返回包含占位符的SQL语句和args参数。
4. `[]func(s *SelectBuilder)`通过函数数组来创建查询条件，可以通过函数调用的顺序和层级来生成 AND OR 这种有嵌套关系的查询条件。





### scanner的实现
```go
func ScanSlice(rows *sql.Rows, dst interface{}) error {
	defer rows.Close()
	// dst的地址
	val := reflect.ValueOf(dst) //  &[]*main.User
	// 判断是否是指针类型，go是值传递，只有传指针才能让更改生效
	if val.Kind() != reflect.Ptr {
		return errors.New("dst not a pointer")
	}
	// 指针指向的Value
	val = reflect.Indirect(val) // []*main.User
	if val.Kind() != reflect.Slice {
		return errors.New("dst not a pointer to slice")
	}
	// 获取slice中的类型
	struPointer := val.Type().Elem() // *main.User

	// 指针指向的类型 具体结构体
	stru := struPointer.Elem()      //  main.User


	cols, err := rows.Columns()  // [id,name,age,ctime,mtime]
	if err != nil {
		return err
	}
	// 判断查询的字段数是否大于 结构体的字段数
	if stru.NumField() < len(cols) { // 5,5
		return errors.New("NumField and cols not match")
	}

	//结构体的json tag的value 对应 字段在结构体中的index
	tagIdx := make(map[string]int) //map tag -> field idx
	for i := 0; i < stru.NumField(); i++ {
		tagname := stru.Field(i).Tag.Get("json")
		if tagname != "" {
			tagIdx[tagname] = i
		}
	}
	resultType := make([]reflect.Type, 0, len(cols)) // [int64,string,int64,time.Time,time.Time]
	index := make([]int, 0, len(cols))               // [0,1,2,3,4,5]
	// 查找和列名相对应的结构体json tag name 的字段类型，保存类型和序号 到resultType 和 index 中
	for _, v := range cols {
		if i, ok := tagIdx[v]; ok {
			resultType = append(resultType, stru.Field(i).Type)
			index = append(index, i)
		}
	}
	for rows.Next() {
		// 创建结构体指针,获取指针指向的对象
		obj := reflect.New(stru).Elem()                   // main.User
		result := make([]interface{}, 0, len(resultType)) //[]
		// 创建结构体字段类型实例的指针,并转化为interface{} 类型
		for _, v := range resultType {
			result = append(result, reflect.New(v).Interface()) // *Int64 ,*string ....
		}
		// 扫描结果
		err := rows.Scan(result...)
		if err != nil {
			return err
		}
		for i, v := range result {
			// 找到对应的结构体index
			fieldIndex := index[i]
			// 把scan 后的值通过反射得到指针指向的value，赋值给对应的结构体字段
			obj.Field(fieldIndex).Set(reflect.ValueOf(v).Elem()) // 给obj 的每个字段赋值
		}
		// append 到slice
		vv := reflect.Append(val, obj.Addr()) // append到 []*main.User, maybe addr change 
		val.Set(vv)                           // []*main.User
	}
	return rows.Err()
}
```
1. 以上主要的思想就是通过`reflect`包来获取传入dst的Slice类型，并通过反射创建对象，具体的步骤请仔细阅读注释。
2. 通过指定的json tag 可以把查询结果和结构体字段mapping起来，即使查询语句中字段不按照表结构顺序。
![](/image/scanner.png)
3. ScanSlice是通用的Scanner。
4. 使用反射创建对象没有传统的方式高效，但是换来的巨大的灵活性在某些场景下是值得的。




## 自动生成

```go 
func FindUserReflect() ([]*User, error) {
	b := SelectBuilder{builder: &strings.Builder{}}
	sql, args := b.
		Select("id", "name", "age", "ctime", "mtime").
		From("user").
		Where(GT("id", 0), GT("age", 0)).
		OrderBy("id").
		Limit(0, 20).
		Query()
	
	rows, err := db.QueryContext(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	result := []*User{}
	err = ScanSlice(rows, &result)
	if err != nil {
		return nil, err
	}
	return result, nil
}

```
生成的查询SQL语句如下：
```SQL
SELECT `id`,`name`,`age`,`ctime`,`mtime` FROM `user` WHERE `id` > ? AND `age` > ? ORDER BY id LIMIT 20 OFFSET 0  [0 0]
```

通过上面的使用的例子来看，我们的工作轻松了不少，第一是SQL语句不需要硬编码了，第二就是Scan不需要写大量的乏味的模板代码，着实帮我们省了很大的麻烦。 但是查询字段还需要我们自己手写，像这种
```go
Select("id", "name", "age", "ctime", "mtime").
```
其中传入的字段需要我们硬编码，我们可不可以再进一步，通过表结构定义来生成我们的golang结构体呢？答案是肯定的，要实现这一步我们需要一个SQL语句的[解析器](https://github.com/xwb1989/sqlparser)，把SQL DDL语句解析成go语言中的`struct`对象，其所包含的表名，列名、列类型、注释等都能获取到，再通过这些对象和写好的模板代码来生成我们实际业务使用的代码，这样写代码就能飞快了。

比如我们生成
```go

var Columns = []string{"id","name","age","ctime","mtime"}
const (
	table = "user"
	Id = "id"
	Name = "name"
	Age = "age"
	Ctime = "ctime"
	Mtime = "mtime"
)
```
那么我们在查询的时候就可以这样使用
```go
Select(Columns...)
```
## 不止ORM

如果我们可以根据表结构生成后端持久层的代码，那是不是我们可以扩展一步，可以不可以把后端GRPC API也同时生成呢？答案是肯定的。
因为在大部分的开发中接口的功能就是暴露API,使外部能够通过RPC调用读写我们的数据库，所以理论上来说RPC接口的message结构和我们的后端持久成model，还有表结构的字段不会相差太大。
![](/image/sql-go-proto.png)
### GRPC API

一般在日常的开发中，我们对表做的一些操作离不开增删改查，我们给外部暴露的API也同样是如此，往往按照标准我们可以定义出针对某个表的 `Create`、`Delete` 、`Update` `Get` `List` 的 Method 和Request以及Response。比如下面的proto定义，用这个做模板，只需要把里面的User相关信息替换就行了。 

```proto
syntax="proto3";
package example;
option go_package = "/api";
import "google/protobuf/empty.proto";
service UserService { 
    rpc CreateUser(User)returns(User);
    rpc DeleteUser(UserId)returns(google.protobuf.Empty);
    rpc UpdateUser(UpdateUserReq)returns(User);
    rpc GetUser(UserId)returns(User);
    rpc ListUsers(ListUsersReq)returns(ListUsersResp);
}

message User {
    //id字段
    int64	id = 1 ;
    //名称
    string	name = 2 ;
    //年龄
    int64	age = 3 ;
    //创建时间
    string	ctime = 4 ;
    //更新时间
    string	mtime = 5 ;  
}

message UserId{
    int64 id = 1 ;
}

message UpdateUserReq{
    User user = 1 ;
    repeated string update_mask  = 2 ;
}
message ListUsersReq{
    // number of page
    int64 page = 1 ;
    // default 20
    int64 page_size = 2 ;
    // order by  for example :  [-id]  -: DESC 
    string order_by = 3 ; 
    //  id > ?
    int64 id_gt = 4;
    // filter xxx like %?%
    // string xxx_contains = 5;
    // yyy > ?
    // int64 yyy_gt = 6;
}
message ListUsersResp{
    repeated User users = 1 ;
    int64 total_count = 2 ;
    int64 page_count = 3 ;
}

```



### GRPC Serice Implement

如果GRPC API定义能够自动化生成，那么GRPC Service的实现是不是也可以自动生成呢？毫无疑问，肯定是可以的。 涉及篇幅就不在本文详细说明。具体的开源实现可以参考[crud](http://github.com/hongshengjie/crud)


## 总结
1. 通过database/sql 库开发有较大痛点，ORM就是为了解决以上问题而生，其存在是有意义的。
2. ORM两个关键的部分是SQLBuilder和Scanner的实现。
3. 通过golang的template模板库我们可以从数据表结构定义直接生成 持久成代码，GRPC API，GRPC Service的实现，通过自动化工具成倍的提升开发效率，开发质量。



## 展望
1. 服务端接口和持久层代码都能自动生成，那么前端呢？前端HTML的`form`或者`table`是否能和我们的GRPC message一一对应呢？JavaScript调用接口的代码也能通过模板自动生成？
2. 未来是否可以只通过设计表结构，通过工具，我们们就能把后端和前端的代码都生成好，实现全自动化编程。我想这个是值得期待的。 


