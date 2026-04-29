
#import "../../common.typ": noindent, project

#show: project

= Network Protocol
Carnegie Mellon University's Advanced Database Systems course is filmed in front of a live studio audience.

"We're all going to die. Okay, in the meantime, let's do databases."

All right, today's class we're going to talk about networking protocols. This will be the second third of the semester, finishing up the second third of the materials. This week and then for the next two weeks we'll talk about query optimization. After that we'll go through and start reading the papers for major systems and understanding how they work, putting the things we talked about this semester and seeing how they're going to be applied by the companies and the people building these various systems.

Last class was all about how to take user-defined functions that the application developer has written because they want to embed logic that would normally be in the application directly inside of the database system and evoke it through a query. The idea was through inlining techniques we can convert the UDF constructs into SQL relational algebra and then have that be exposed to the optimizer to figure out what the user function actually wanted to do. This is the example of pushing the application logic into the database system.

As I said at the end of last class, today's lecture is about how to do the opposite: get data out of the database system and bring it over to the application so the application can process it and do what it wants.

We'll first talk about what these different database access APIs look like. Then we'll go into more details of what the network protocols look like, and that was the paper you were assigned to read about — what the bits look like and how it's inefficient in modern application scenarios where data scientists may be working in pandas or some Python notebook and just want to do a `SELECT *` and get a bunch of data out and then do all the processing on the client side.

We'll see how the major database systems today — the existing protocols — are insufficient or not designed for that kind of workload. The answer is going to be Apache Arrow. The paper you read came out before the Arrow Database Connectivity library stuff was defined, but they are basically reinventing the same thing, and ADBC and Arrow would do the same thing. We'll build up to that.

Then we'll talk about additional optimizations we can do on the server side to make things run faster at the networking stack or potentially for other parts of the system, by either doing kernel bypass or userspace bypass. Then we'll finish up quickly talking about additional optimizations we could do on the client side if our Python programmer is talking to a database system and is going to put some data into a data frame.

Some of the things we'll talk about today will be applicable for backend communication between the various database workers in your system. If it's a parallel system and one worker needs to communicate with another worker, or needs to communicate with the optimizer service or the scheduler service, a lot of these things we'll talk about will still matter. Certainly kernel bypass stuff could help, or userspace bypass stuff can help. But we're going to mostly focus on how we actually expose data to the client and how to make that run efficiently. We'll see when we go through the discussions of the real-world systems where some optimizations we can apply in the backend.

Last class I showed a really quick demo of opening up the `psql` terminal, writing a SQL query, hitting enter, and getting back some results. That's a basic API access method to the database system where you're sending a SQL query and getting back results that are meant to be printed out on the screen because it's meant to be interpretable by humans. But most queries aren't going to run like that. Most queries are going to want data in a typically binary form because it can be fed into some kind of application code that wants to do some additional processing on it. In my example of the terminal, that's just plain text, and in that case PostgreSQL is actually going to send plain text data over the wire back to the client. We'll see one system in particular that actually does that no matter whether it's talking to an application or a terminal. But most systems are going to be doing binary serialization.

You wouldn't actually want to write your application by just piping out to `psql` or whatever the command line terminal you want to use. Instead, you're going to write your application using one of these different methods. These aren't mutually exclusive. Depending if your application is written in C\# or C++, you would use this; if it's Python, you use that, and so forth. Various systems are going to support some of these, but the thing that we're really going to care about is the low-level network API of how we're going to put bits on the wire. All of these methods, except for maybe the last one, can hide all that.

The first one is a proprietary API that the system exposes to you typically through a C library. You wouldn't want to write your application this way — if you're writing a driver for these other ones, you would use these kinds of things. You can look at the documentation for MySQL or PostgreSQL — they all have information about the API for the low-level C library: how to open up a connection, how to send a query, how to do authentication, and so forth. You can use ChatGPT to write this kind of stuff. You basically say, "Write me a C or C++ program that uses libpq," which is the low-level C API interface that you would use to program PostgreSQL. But you typically don't write programs like this. You'll use some other abstraction, an even higher-level abstraction like an ORM — Django Active Record, Ruby on Rails, SQLAlchemy, Node.js. Underneath the covers, they may be calling the C API, but the application programmers aren't writing code for these things.

So I want to focus on these two. Python came later in the 90s, but you'll see how things get built up over time. A lot of things we'll talk about for JDBC is applicable for whatever your favorite programming language that has a specification of how to do database connectivity, and they would follow through the same thing. The big idea of what these APIs are going to do for us is that instead of programming against the low-level C API, we could program against these database system agnostic APIs. Then if we decide to change what database server or database system we want to use, we wouldn't have to change any of our application code. Of course, that's not entirely true if you're writing raw SQL, because as we said many times, the SQL dialect could be different from one system to the next, but we can ignore that.

The history for this goes back to the late 80s, early 90s. Prior to something like ODBC, it was just these C libraries that all the various database system vendors provided. Things weren't portable. You were writing to a low-level API to talk to a database system that was very specific to the one database system you were using. People identified early on that it would be nice to have a standard way to do database connectivity and to send queries to get back results. I think the first attempt was in the late 80s from Sybase. They had something generically called DB-Library that was meant to be an open standard that everyone could implement. But that didn't go anywhere.

Then Microsoft teamed up with another company called Simba Technologies in the early 1990s and they put forth ODBC. Now pretty much every database system that you can think of today is going to have an ODBC implementation, even if it's actually not a relational database system and doesn't support SQL. MongoDB has an ODBC implementation because at some point you have to put in the query command that you want to send over, and ODBC doesn't care whether it's SQL or not. There are other APIs to iterate a result set, bind parameters to values, and so forth.

ODBC is based on the device driver model, similar to how hardware works in PCs. If you buy a graphics card, the vendor is also going to provide you with a driver that you can install in your OS to communicate with the hardware. Same idea: the database system vendor is responsible for providing you with a driver that you can use based on the ODBC spec to communicate with the database server. If the application wants to run some queries on the database, they go to the ODBC driver, and the ODBC driver is responsible for sending the request over to the database server, getting back the result, and then marshalling it back into the form required by the ODBC spec, then exposing it to your application.

This can mean things like if my client is expecting everything to be 32-bit integers but the database server sends me back 64-bit integers, the driver is responsible for converting that and cleaning things up. It also does other things. There are certain features in the ODBC spec that the database system doesn't support — cursors, for example. PostgreSQL doesn't support true cursors. The driver can emulate that: send the query over, give you back a cursor to it, and you're just iterating over the results that are cached on the client side. You can do a bunch of stuff in the driver.

The thing we care about today is this piece: the request going out and the response coming back. We're going to call this the wire protocol, the network protocol of the database system. This is what we're going to focus on.

**Student question:** For example, where do commands get inserted into the stream? Do they run through the query optimizer, or do they just get converted to SQL and go through everything?

**Professor:** The question is, if I have a SQL query, where does it get converted to a plan? When you're using ODBC or standard calls, there will be a prepare statement command and you put a string in that will be whatever the flavor of SQL that system supports. There's no way that can be universal across database systems, but the API call to say "here's the query I want to run," then you execute it, get back a result, iterate over the result set, give me the second attribute as an integer — all that is standardized. But the SQL itself just goes over the wire, and then all the parsing, planning, optimizing all happens on the server side. This is basically going to be calling the C API that I mentioned before.

ODBC was the first one, the big one that really took off. In the early to mid 90s, everybody was supporting ODBC. Then Java comes along in the mid 90s, and Sun recognized that if you want to be able to use Java applications in the enterprise, they need to be able to talk to database systems. They had to support something similar to ODBC but for Java. At the time, ODBC was very much Windows-specific. Since then it's expanded, but at the time it was Windows-specific and for C++ applications. It wouldn't work in the Java world.

In the same way that Rust is the hot thing now, Java was the hot thing in the mid 90s. The idea was you write your program once and the JVM can then run it anywhere — that was mind-blowing for people back then. Go was the hot thing 10 years ago. There's always some kind of fad.

JDBC comes along. You can think of it as basically the same thing as ODBC, just now it's for Java instead of C. But because they were trying to bootstrap this new connectivity API to an existing ecosystem of database systems that already were part of ODBC, and they wanted people to get up and running with any possible database system as soon as possible, they had different variations of how you can build a JDBC library or implementation. They have various methods to bridge the gap between what was available at the time versus what came later.

The four approaches are:

1. There is no native JDBC Java implementation of communicating with the database system. Instead, you provide a bridge or wrapper in Java that then invokes ODBC — the actual shared objects, the C code — that then communicates with the database system. This was meant for if you have a database system that doesn't support JDBC yet, you could just wrap something around ODBC and use that.

2. You would have JDBC calls make JNI invocations down into the C code of the C API and have that go over the wire to talk to the database system. Taking the bits, putting them into buffers, all that was done in C, and then it was just copying the data up into Java.

3. You have a separate middleware, a separate server running that the JDBC thing would talk to, and then that middleware would use ODBC to talk to your database system. It's an extra hop to make the call.

4. The most ideal: you have a pure Java implementation that makes the JDBC calls from the application directly into the vendor-specific wire protocol commands. Every single database system at this point is going to have their own native Java JDBC implementations. Think of how many times you come across something in Rust or Cargo you want to use and there isn't a native implementation — it's just calling into C. That's really the top one. The top one has been removed, and this is the best one, and this is the most common one at least for the most major database systems today.

The thing we care about is what's being sent over the wire to communicate from the client, whether it's ODBC, JDBC, or whatever, to the database server. Every database system for the most part is going to implement their own proprietary wire protocol typically over TCP/IP. It's going to use that to send the bits back and forth, acknowledgements, take queries in, and get responses back.

If you're running on the same box and it's Linux, you can use Unix domain sockets to get faster performance because you're not going through the full TCP/IP stack and the OS on both the client side and the server side. You can do this in PostgreSQL, but again if you're running in the cloud, the DB server is in some far away location, you're not going to be able to do this.

I'm not aware of any system that uses UDP to communicate between the client and the server. TCP has overhead because you have to send the acknowledgements back and forth. With UDP, you throw it over and hope it makes it. No system I'm aware of does this between the client and the server. One system later on, Yellowbrick, they'll actually use UDP to communicate between the backend servers because it's just so much faster, and they basically have to do their own retry and acknowledgements on their own. But in that case, because they're trying to get the best performance possible, it was worth it for them to implement this. PostgreSQL uses UDP to communicate between the stats collector and the different workers, but that's all in the backend on the same box, again not between the client and the server.

Typically what happens is the client comes along and connects to the database system. There's always going to be some kind of authentication process — either you're given a token because you've authenticated with something else, or you do username/password, or whatever the mechanism is. Ideally you want this to be using SSL or TLS so people can't sniff your packets. Then you send over the query. The database system will block that connection — well, it's not true because you can do asynchronous stuff — but it'll run that query. As soon as it starts getting results, it serializes them and sends them back over the wire. Some systems can do cursors, for example, and start spooling some of the results even though the query is still running. But as far as I know, most cloud systems, once you get all the results, then they start sending things back. Obviously it depends on the query too. If the root node in the query plan is an ORDER BY with a LIMIT on it, you need to see all the data before you can start sending anything up.

The thing we care about today is this step here, and we'll talk a little bit at the end about what we can do to maybe speed that piece up.

In the paper you read, they talk about how this part is actually not that big of a deal. We spent the whole semester so far talking about how to build a fast database system, how to run queries really fast. Obviously if you're reading page data, that's going to take a long time. But in the paper you read and this other work that came out called ConnectorX, this thing is actually the most expensive part — just sending that over the network and back to the client.

The queries themselves aren't going to be that big. The biggest SQL query that you can get is going to be like 10 megabytes — the SQL string. So that's not expensive to send. It's sending the results back that can be very expensive because you may have to copy it into the form that the client or network protocol wants, and that may not be the same as how it's natively stored in the database.

**Student:** How would a SQL query reach 10 megabytes?

**Professor:** This example actually comes from Google. They told me they had, and it's not hard to imagine, some dashboard where you can click a bunch of checkboxes of what you want to visualize. All that's doing is concatenating search options in a giant IN clause, and before you know it you got a 10-megabyte SQL string. It's rare, I'm not saying it's common, but you can imagine something like that.

We didn't really talk about tricks of how to make IN clauses go faster. If your IN clause is huge, you basically build a hash table on the expression itself, then use that to probe when you do lookups. It's like a join. You can think of an IN clause as almost like materializing another temp table if it's huge.

If you're going to build a new database system today, you have two choices. You either can implement your own wire protocol from scratch, in which case you have to write your JDBC/ODBC client libraries and drivers to support talking to your database system. The more common thing to do now is just use an existing wire protocol from an existing database system, because then you can just inherit their driver ecosystem for free.

It's not enough to just say, "I speak the wire protocol" to say you're compatible with another database system. That would be the bare minimum. If you just spoke the wire protocol, the client drivers typically don't know and don't care what the SQL query looks like. They're not parsing on the client side to see if you're really sending a PostgreSQL-compatible query; they're just sending the text over. If you want to be able to support more of the ecosystem, then you have to support the catalogs and other functionality. But the bare minimum you would need is just to speak the wire protocol.

It's about 50/50 now. It didn't used to be this way, but the two most common wire protocols that are going to be reused are MySQL and PostgreSQL. MySQL used to be number one. PostgreSQL is becoming more and more popular. That's partly because there are a lot of databases that are forks of PostgreSQL where they keep the top half including the network layer, so you're speaking the wire protocol, and then they rewrite the bottom layer. That's what Neon does, and Redshift, and others. The third most common wire protocol is actually Redis because it's so simple — it's just text-based, getting sets and simple things like that. If you support these existing protocols, someone can run against your new database system without having to rewrite their application or change what driver they're using, because you just piggyback off the existing driver implementations.

Snowflake interestingly did not do this. I think it was a different time. Snowflake decided they were going to write their own wire protocol from scratch, including their own SQL dialect from scratch. They started around 2011-2012. If you're going to build a new system today, it would be a hard decision to do that because there's just so much stuff you can reuse if you speak the PostgreSQL wire protocol.

The paper you read was about how to improve the wire protocols between these different database systems, and they focus on four key design decisions. The background of this paper is that it's from the MonetDB/Lite project, which was a precursor to DuckDB. Hannes Mühleisen and Mark Raasveldt, who are the authors of this paper, as part of the work they were doing when trying to make MonetDB embeddable, they realized all the problems they were having of getting data in and out into pandas and R programs — even if you're running on the same machine, in the same process. This is what led them to throw away the code and start building DuckDB. This is the same team, but before DuckDB was a thing.

This paper is focused on doing large data exports. It's not complex queries doing a bunch of joins and sophisticated aggregations. It's more or less `SELECT *` queries, or even getting a subset of the columns out, to then be able to feed that into a pandas or Python program to do additional computation or train machine learning models.

This paper is really about how to get data out of the server into the client. Whatever optimizations we're going to talk about today, you're going to have to also implement them in the client driver. If you start compressing things on the server side and send that over the wire, if the client doesn't know how to decompress them, then the data is useless. Likewise, if I convert from a row-oriented format to a columnar format, if the client doesn't know how to handle that transpose, then it's all useless.

Typically client drivers are very conservative and they're not going to want to have a lot of extended capabilities in them because now you have to support that for every single possible language you ever want to support. If you have the C API and you just wrap that around the various different programming languages, then that's fine because you implement it once. But as I was saying before, ideally you want to have a native implementation of your client driver in whatever programming language you're running in so you don't have this copying over between C and whatever programming language you want. If you have all these additional features in your client driver, every programming language that implements your client driver has to implement the same thing, and that could become problematic because people don't implement all the same capabilities. There's a trade-off between how sophisticated we can be versus what people are actually going to be able to do with the client drivers.

Furthermore, in a modern scenario — we haven't really talked about Lambda functions or serverless applications — a very common scenario now is the communication between the database server and a Lambda function. I spin up a Lambda function, which is some Python thing that runs, connects to the database server, does authentication, sends some queries, gets back results, does some minor processing, and then goes away. In that case, you're paying for the compute time on the serverless function and you don't want to have to do a bunch of expensive deserialization if you have a very sophisticated client protocol. The answer is going to be Apache Arrow as the right solution to this.

We're going to go through four major pieces and see what the trade-offs are, not just for performance but also from the engineering side on the client.

The first one is kind of obvious because this is why we started off the semester: row store versus column store. ODBC and JDBC, by their nature, are row-oriented APIs because they were developed in the early 1990s before columnar databases were a thing. The paper on columnar databases — the first one in column stores — is from '82-'83, but that's a theory paper. There was a Swedish system that was technically a column store in the 70s, but no one's ever heard of that. Sybase IQ is probably the first one that came along that was a true columnar implementation, but that's like '97-'98. ODBC comes along in 1990 — column stores aren't a thing. Most applications people are writing are business applications that are fetching one order record or single entities, single information. So inherently row-oriented.

In this world, the server is going to take all the tuples it's getting as part of its output, and even though on the server side it may be storing them as a column store, it's going to stitch them back together, materialize them back together, because the client protocol, the wire protocol, wants it in a row-oriented manner. Then you write applications with pseudo-JDBC code: you iterate over the result set and get one tuple at a time and extract out the data you want row by row.

But if we switch to a columnar format, then this technique could be bad too because if I ever need to get multiple data for a single tuple across multiple columns, then I have to write some weird code like iterate over the columns and iterate over the rows and try to stitch things back together. This is not real code, just some pseudo code here.

The solution is basically the same thing we talked about at the very beginning: we want a batched columnar model, because now we can operate over batches of tuples. Although we're going to be sending the data out in a columnar fashion, we'll group them together in row groups or small enough chunks where all the data we would need for a single tuple will be close together. This is what Arrow does.

Arrow has a thing called the Arrow Database Connectivity (ADBC). It's basically like JDBC or ODBC — it's a specification, a programming API for how to interact with a database system and operate over vectors. If your database system supports ADBC, which some systems do like Snowflake for example, then I can make requests, send a SQL query over to the database system, and get it back in native Arrow form. Then I can integrate that and use it in my application any way that I want without having to do any copying or deserialization because it's already in the Arrow vector format.

We're not going to go through ADBC in detail. Not everyone actually supports it, but this is basically what Hannes and Mark are going to propose: "Hey, wouldn't it be nice if we had this vector-based API?" And this is what came out later, because the paper you read predates ADBC.

Now, assuming we're sending things back as vectors, how do we want to support compression? This is going to be similar to all the stuff we talked about before in storage — the trade-off between having general-purpose or naive compression, just taking blocks of data and throwing gzip or Snappy at it, versus having a more lightweight encoding scheme specific to the actual data that I'm storing.

The easiest approach is to just do gzip, Snappy, or Zstandard. You do all the same wire protocol construction of the packets and messages that you would normally do, but right before you send it over the wire, you just run gzip or Snappy on it to compress it before it sends it over, and the client does the reverse. This is not that common. It's not on by default for most systems. I know for Oracle, and actually Snowflake might be on by default. Oracle, MySQL, and BigQuery, these are things you can go add on after the fact. BigQuery is doing this over HTTP, so I think it's just part of the HTTP client protocol — they're adding gzip. Oracle added this in 2013. MySQL had it for a while. There was a patch to add this in PostgreSQL in 2018, but that didn't go anywhere, so PostgreSQL doesn't support this.

The next approach is again doing all the stuff we talked about before: using dictionary encoding, RLE, delta encoding, frame of reference encoding. The idea is that you recognize the data type of the data you're sending back for the response, and you just run whatever compression scheme you want on it. Nobody does this except for Arrow, because if you get data back as Arrow, it'll already be dictionary encoded — but that's the only coding scheme that Arrow supports out of the box. They're not doing delta encoding, RLE, and so forth. Again, nobody does this because you would have to have all your client drivers also support this.

Typically the way it works is when your client connects to the database server, like when you do an SSH handshake, you say "here are the features I can support," and the client and server then pick the bare minimum they would have. So you could have a bunch of clients showing up with old driver implementations that don't support any of these things. From the engineering side, you have to support this in all the different implementations.

**Student:** Is it really either/or? Can't you have both — column-specific encoding and then gzip on top?

**Professor:** Yes, they're not mutually exclusive. You could do both. Furthermore, depending on how you serialize the data — if you're just doing text encoding and you pad things out — then this one is going to make a big difference versus this. They're not mutually exclusive, but I'm saying nobody as far as I know, other than ADBC, does this because the drivers have to support it.

Basically everything I'm saying here is all the things we talked about earlier when we talked about getting things from the object store from disk. When the communication channel between the storage or between the client and the server is slow, then heavyweight compression is going to be much better because we're willing to pay that trade-off of spending more CPU cycles to compress the data down to smaller sizes because that'll speed things up as we send it over. Obviously the larger the chunks of data we're sending over, the better compression ratio we'll get.

Next is how do we serialize and encode the data we're sending over. The first approach is the most common one: binary encoding. You're basically sending the data from the client to the server in the same low-level binary form that it's being represented in your database — at least ideally, not always the case though. The client is responsible for dealing with any endianness issues. If the data is being stored in little endian and your client is running on a big endian machine, the client is responsible for doing that conversion. The idea is the database server is just trying to get you data as fast as possible, and the clients — since there are more clients than servers typically — can spread out the computational cost of doing that conversion across all the different clients.

Another question is: if we want to use binary encoding, how are we going to decide what serialization scheme we're going to use? In the paper you read, they argue that rolling your own serialization format is better than using existing libraries, because these existing libraries bring up a bunch of other infrastructure that you may not care about that adds additional computational overhead, storage overhead, or space overhead for the packets you're sending back.

You can write your own serialization format to take a result set of three attributes — integer, float, whatever — and pack them down into the byte representation that you then send over the wire. Alternatively, you use one of these libraries like Protocol Buffers, Thrift, or FlatBuffers (the newer one, the better one). There's Cap'n Proto, a bunch of others. They provide you with the capabilities to define what the schema of the messages you're sending is and serialize it.

One year somebody asked me, "Why doesn't any database system store data natively as Protocol Buffers if they're going to be sending data back through Protocol Buffers?" I was like, "Nobody does that. That sounds like a bad idea." Turns out somebody does do it, because they emailed me later. There is a system — I think it's a toy project called Protean — where the wire protocol sends out Protocol Buffers and internally storage they're storing everything as Protocol Buffers as well because it's just bytes. In that case, you don't do any deserialization or serialization when someone requests something, because you just send over the stuff you've already stored as Protocol Buffers. I'm not saying it's a good idea, but it does exist.

The other challenge with Protocol Buffers is that at least that one is separated enough from gRPC where you don't have to bring in all the infrastructure for gRPC. But Thrift, as far as I remember, you bring in their threading models, thread pools, buffer pools as well. It brings up way more infrastructure if you choose to use this. FlatBuffers is pretty simplistic and it's just the serialization format. There are other things that these provide you which may not be useful. They can keep track of the versioning of your messages. Over time, if you expand the capabilities or the internal data members of the packets of messages you're sending when you send back results or take queries in, Protocol Buffers will keep track of the different versions so you know what version of the API you're interacting with.

The other approach is text encoding. This is the simplest thing to do: no matter what the data is, you run the equivalent of `to_string()` on it to convert it from the binary form to a string form, and then you just send it over as variable-length strings to the client. This one is nice because you don't have to worry about endianness — it's ASCII or UTF-8 format. The client then takes your text and converts it back to the binary format and they can put it in whatever form they want. For missing values, you could have a separate bitmap to keep track of what values are null. In MonetDB, they just store the value "NULL" — literally the string "NULL" to represent a null string.

**Student:** So is this a good idea or a bad idea?

**Professor:** What happens if you have a string in your database that is just "NULL"? What do you do? I don't know what MonetDB does. Is this a good idea or a bad idea? Why?

**Student:** It explodes the size of the data.

**Professor:** Why do this? Why can't we just say, "Okay, this is the start of the string, this is how long it is, treat the next couple of bytes as a string"? You don't need to translate it at all. What is the encoding actually doing here? If I have a 4-byte 32-bit integer, 123456, when I send it over the wire to the client, I'm literally going to convert it into the ASCII string — character '1', '2', '3', '4', '5', '6'. I'll either store the length of the string in front of it, or I could do null termination. But every piece of data that I'm sending over in a record is going to be a string form of it.

In binary encoding, this is 32 bits to store this number. In text encoding, each of these characters is one byte for the ASCII character. And you have to store the size as well, or the null terminator, or keep it fixed length.

So good idea or bad idea? Bad idea. It's bigger, more data. And obviously, if you use that, then what happens? Instead of compression, you've gone the wrong direction.

**Student:** But if you put gzip on top of this, it's going to compress fantastically.

**Professor:** Possibly. Why would gzip on approach two be better than on approach one? Because there are more things to compress.

**Student:** But that doesn't make sense because you're increasing and then going back.

**Professor:** If you run gzip on the 4 bytes versus on the 6 bytes plus the null terminator or the length, the end result — which one will be smaller?

**Student:** Surely the database knows better about how to serialize than just always doing the same text encoding.

**Professor:** The database system would know better how to serialize this rather than always doing the same thing. In theory, yes. Would you want to spend the time on the server side to do that and figure that out? We'll come back to this.

Most systems are going to do binary encoding but roll their own and not use one of the existing libraries. But then it's all the stuff we talked about before when we talk about data file formats — we have to do the null mask, keep track of data types, the sizes of the data in the messages. That's fine because we know how to write that stuff because we had to do it for storage anyway. It's just more work, whereas Protocol Buffers gives you a bunch of stuff for free, but it's all things in CS — you pay a cost.

We've already talked about how you represent the length of strings. You could do the C-style with a null terminator byte at the end. The client can just scan along until it finds the null and says, "Okay, now I have all the data that I need." This makes it harder to do jumps into fixed-length slots. If you're trying to send things as vector batches, the most common is length-prefixed, which we talked about before. Some systems, I think MonetDB, they're just going to pad out the string with additional characters to be whatever the max size of the attribute could be. If I have a VARCHAR(16) and I have a bunch of 4-character strings, it's just going to pad out the rest with a bunch of spaces.

**Student:** Which approach is going to be the best?

**Professor:** Which approach is going to be the best? Why?

**Student:** Fixed length with padding. Because if it's fixed-length and you're padding with zeros, gzip can take care of that. Also, if it's fixed-length, you can jump around much faster.

**Professor:** Yes. If it's fixed-width and padding to zeros, gzip can compress that. Also now everything is fixed-length, you can jump around as needed and you don't need to decode first. It depends on what the query wants to do with it. Furthermore, if the column is a VARCHAR(1024) and I have a bunch of one-character strings in it, then that's wasting a ton of space.

**Student:** Why would people do that?

**Professor:** People are stupid. You see all sorts of crazy things on real databases.

**Student:** Does approach one (null-terminated) have any advantages?

**Professor:** On the server side, you can reuse C string functions. When we built our first system, my second or third year at CMU, we did this. And then when we went over the wire protocol because we were speaking the PostgreSQL wire protocol, PostgreSQL didn't want a null terminator — we didn't have to copy the string and add the length in front of it.

**Student:** Even if you have one character in a VARCHAR(1024), won't gzip take care of that if you're padding everything?

**Professor:** Yes, gzip takes care of it. But it takes time. Even Snappy or Zstandard would be fast, but not all database systems support



The Postgres wire protocol itself has no notion of compression. You can hack it by tunneling all your traffic over SSH and compressing that, but that’s an extra hop and sounds crazy.

As far as I know, even in 2024, Postgres does not have a flag to indicate compression. MySQL has it, Oracle has it, but many other systems do not. Sometimes one approach is faster; sometimes another is faster. No system tries to automatically decide based on your data or query which approach to use, because that adds engineering overhead on both the server and client sides and isn’t worth it.

If your dataset is small, this approach is fastest. If everything is fixed-length (e.g., char fields), this is also fastest because you don’t need to store lengths.

These design choices are not independent. Choosing one affects others, such as which compression scheme to use. This is similar to what we discussed for on-disk data.

---

Let’s look at some graphs.

First, consider sending a single tuple from the database to the client. This highlights the overhead of infrastructure around message handling. Most systems use ODBC; Hive uses JDBC.

The results are ordered by performance. One surprising result: MonetDB uses text encoding (converting binary data to strings), yet it is still among the fastest. Others use binary encoding.

Why are some systems slower?

* Hive is slow because it uses Thrift, which introduces extra memory copies and sends additional metadata about message structure. This increases message size.
* DB2 is slow because it reimplements acknowledgments on top of TCP/IP, making the protocol overly chatty.

These inefficiencies dominate, even though the actual data being transferred is small.

---

Now consider sending more data: one million tuples from TPC-H.

We vary network latency artificially.

For MySQL:

 Without gzip is faster when the network is fast, because compression overhead dominates.
 With gzip becomes better when latency is high, because reducing data size outweighs CPU cost.

This matches what we saw with storage systems like S3:

 Compression hurts when the network is fast.
 Compression helps when the network is slow.

All systems show increasing latency as network slows. Interestingly:

 Oracle is fast on fast networks but becomes slow on high latency networks.
 DB2 remains the slowest.
 Hive can outperform DB2 at high latency.

Again, protocol design matters.

Another experiment (from Peloton/NoisePage):

Goal: maximize throughput of transferring a 7GB table (TPC-C order line) to a client.

Approaches:

1. Postgres wire protocol (row-based, no compression)
2. Vectorized protocol (columnar/PAX format)
3. Apache Arrow (native format, no conversion)
4. RDMA (kernel bypass, direct memory transfer)

Results:

* Arrow is faster because there is no conversion.
* RDMA is fastest because it avoids CPU copies and kernel overhead.

Conclusion: If you’re building a modern system, sending data as Apache Arrow is the right approach.

---

However, the network protocol is not always the bottleneck. The OS is often the real problem.

TCP/IP is slow because:

 It relies on interrupts.
 It requires context switches.
 It copies data between kernel and user space.

We want to avoid the OS as much as possible.

---

Kernel bypass techniques:

1. DPDK

    User-space access to NIC.
    No kernel involvement.
    Requires implementing your own TCP/IP stack.
    Very complex; rarely used in practice.

2. RDMA

    Direct memory access across machines.
    Hardware handles data transfer without CPU.
    Requires careful coordination and permissions.
    Used in specialized systems (e.g., Oracle Exadata).

3. io_uring

    Asynchronous I/O interface in Linux.
    Reduces syscall overhead.
    Still uses kernel, but more efficiently.

In practice:

 DPDK is powerful but extremely hard to use.
 RDMA gives big gains but is complex.
 io_uring is promising but results are mixed.


Alternative approach: **User bypass (eBPF)**

Instead of bypassing the kernel, push logic into the kernel.

eBPF allows:

Safe execution of custom programs inside the kernel.
No recompilation of the OS.
Verified execution to prevent crashes.

Use cases:

Packet filtering
Observability
Lightweight processing (e.g., proxies)

Example:
A Postgres proxy implemented with eBPF shows significant performance gains because it avoids copying data between kernel and user space.

---

Finally, client-side overhead:

Even if data transfer is fast, converting results into application formats (e.g., pandas DataFrame) can dominate cost.

Solution:

* Use Apache Arrow with ADBC to avoid conversion.
* Or use parallel query splitting (e.g., ConnectorX) to fetch data in parallel and populate data structures faster.

---

Key Takeaways

* Network protocol design matters.
* Compression trade-offs depend on network conditions.
* Apache Arrow is the best modern data transfer format.
* Kernel bypass can improve performance but is complex.
* eBPF is a promising direction for future systems.
* Client-side data conversion can be a major bottleneck.

---

Next topic: query optimization.




I said post doesn't support this. Post wire protocol itself has no notion of compression. You can hack it by like tunneling all your traffic over SSH and compress that, but that's an extra hop and that sounds — that sounds crazy. But like the process wire protocol, as far as I know, in 2024 does not have like a flag saying this is going to be compressed. MySQL has it, Oracle has it, not other systems do not. So again, sometimes one is going to be faster, sometimes two is going to be faster. No system is going to do both. No system is going to try to figure out, okay, based on what the data looks like and what your query looks like, I'm going to give you one versus the other, because again that's more engineering overhead that you got to support now on the server side and on the client side, and it's just not worth it. Right. This will be the fastest if your data set size is small. If it's all char ones, this is going to be the fastest because you don't store the length.

Okay. I'm going to show — I say also too, like as all things we talked about before, these aren't independent, right. Like if I choose one of these, that'll affect how what kind of compression scheme I want to use. That's very similar to the stuff we talked about when we talk about data on disk. So I'm going to show two graphs here. So the first is going to be what happens when we just send one tuple from the database system to the client. And the idea is here just to look at what the overheads of like just all the infrastructure around the messages of sending the query and getting getting back the result. And so for all these systems except for Hive, these are all going to be using ODBC. Hive is going to be using JDBC, and I think I forget the reason why they did that.

So here's the numbers, right, and they're listed in order of performance. So the first thing to point out here is that here's MongoDB that's using the text encoding thing that we talked about before. They're sending over converting all the binary data into string form and sending that over, right. All the other ones are using binary encoding, but yet MongoDB is the what, second fastest or third fastest? Right. Why? Power of gzip. It says power of gzip. Faster without gzip? What's that? Seems to be faster without. Yep, that's probably one gig. Would so is gzip helping him here? So all right. So let's talk about why the other ones are slow. So the slowest one is Hive, right. The reason why that's according to the paper why that's slow is they're using Thrift. So Thrift is going to do copying things in and out of Thrift buffers, so that additional memcopies to get data onto Thrift on the server side and then on the client side copying out of their buffers as well. And then Thrift is also sending over a bunch of different metadata about what the structure of the message is going to be. They're sending that over as well, so the size of the packet, the message for sending the same tuple as all other systems, it's just much much higher.

DB2 is the second slowest because they're actually — I mean Oracle does this as well, but for some reason it's more pernicious than this one — they're actually also basically reimplementing acknowledgements on top of TCP/IP. So TCP/IP is already going to be doing sending ACKs back. They're going to be doing that as well above that to make sure that, okay, I got your message for this DB server, for this I got this packet, I'm ready, give me the next one, right. So the protocol itself is just way more chatty because for some reason they're reimplementing this idea of acknowledgements. Yes, was it based on P earlier? Is that why they — his question is, is it based on UDP? I have no idea. This also too, since it's a proprietary protocol, they can't see the implementation on the server side. This is what in the paper they speculate.

Yes. How is it possible for it to be so slow on like one? Like how many bits is that? At most. Say oh for TPC-H, it's less than a kilobyte. How take a whole — I think also too for like this is like I think this is end to end time, right, and not like just sending the message. So like this is sending the query and then Hive basically converts the query into a MapReduce job, then it dispatches that, gets back the result, and sends it back. So I think it includes that, but I have to double check. And this — is the client on the same machine as the server? Let's see what else they say. They minimize query execution time, they would query the query multiple times, the system would cache the query plan and the result. Ah, I take back what I said. It wasn't running MapReduce. It literally is just like how to get data in and out as fast as possible, right. It's one second, it's long. Hive's not — Hive is not a great system. There's a reason why Facebook ditched it and rewrote Presto, right. Hive was the stopgap solution in the late 2000s. When and I was sort of part of this, like Hadoop came out, the MapReduce paper came out from Google. Yahoo took it, started reimplemented the ideas as Hadoop. Hadoop was like the hot thing. Everyone's like this is amazing, this is how you should be doing analytics and Big Data stuff. The relational database people, which I was a part of, we were like, you guys are all doing it wrong. You're reinventing stuff that was in the 90s for parallel databases, distributed databases, and like declarative languages like SQL is a good idea, processing data on partitioned tables, that's a good idea. And then people realized, oh yeah, writing these MapReduce jobs in Java sucks. Be nice if we had SQL. So then they built Hive, which is basically a translator from SQL and it would then generate a MapReduce Java program. So yeah, you're making a face, it's — I'm not saying it's a good idea.

For this again, they were surprised by how slow DB2 was, again as he was saying it's such a small amount of data, but again I think the protocol is just so chatty.

Right. All right. So let's now look — we send more data. So for this one we're going to send a million tuples from TPC-H and what they're going to do is they're going to scale along the x-axis. They artificially slow down what the network latency is between the client and the server. And so the first line I want to show is just for MySQL with gzip and MySQL without gzip. So what this basically corroborates is what we talked about before with storage, getting things again from S3 or the object store whatever. When the network's really fast, you don't want to compress the data because the CPU cost of doing that additional compression is just not worth the penalty, or it's not worth it because the network is so fast. And so that's why you see this gap here when the network's really fast, not using compression is the better way to go even though you are sending more bytes. And then even though we are log scale here, but as we get to a slower speed, so 100 milliseconds for the latency, again we're log scale, the compression one actually is slightly better, right, because in that case the CPU overhead is not the dominating factor of getting the data out. Right, it's basic — like compression overhead is bad when the trade-off is the network is fast, right. So now we bring back all the other ones, right, and they all basically converge or moving along in the same way as expected. The time it takes to get the data out of database server goes up as the network gets slower, but what's surprising here is that you can kind of see that in the case of Oracle, they're one of the faster ones when the network is fast, but then as the network gets slower, they're now the second slowest. Right. DB2 is always the slowest. Hive actually beats — yeah, Hive is actually beating DB2 on the slower network. And so Oracle is a proprietary protocol, we can't see the implementation of it, but they speculate — they speculate again just like in the case of DB2, Oracle is also sending their own acknowledgements back and forth, and it just becomes more dominating cost when the network gets slower. So again, all of these except for — sorry, except for MongoDB — are binary protocols, but MongoDB is actually what, the third best after MySQL, MySQL gzip, because it's simple.

Yes. The benefit from compression also applies to the others. The question is, do you get the same benefit of compression for the other systems as MySQL? I would assume yes. Like Oracle you could test it, I would say yes, because the Oracle wire protocol — the actual bits themselves may be different than what MySQL is, but it's a binary based protocol like MySQL, so it probably be the same. Only — actually why do they only turn on gzip for MySQL? I don't know.

Yeah. Okay. So I'm going to show another result from a different paper. This is a paper we wrote with one of my former former master students, now PhD student at MIT, and then with Wes McKinney, the guy from Apache Arrow. So for this one, this is from our older system Pelaton or NoisePage and it was the idea was how fast can we get the line item table out of the order line table out of TPC-C, so a seven gigabyte data. How fast can we get it to the client? So the client isn't doing any computation on it, it's just how fast can you get it. And so our system supported the post wire protocol. So this is the default, like post wire protocol without compression, row based. This is how fast you can get the data out. So natively our system was storing everything as Apache Arrow tables. So that in our system you could do transactions, then over time as the data got cold and you weren't modifying anymore, it would just then flip some bits around and then it would natively be storing Apache Arrow. So this next bar here is what you get from what they were proposing in the paper you guys read, like here's the vectorized version of the post wire protocol. We're sending things as a page format rather than as row oriented. But then the next approach is using early precursor to ADBC, the Arrow connectivity stuff, where this is like natively sending out the Apache Arrow data in its form without doing any translation, just natively shoving that to the Python application. And so it's faster because there's no conversion to convert it into a different form, right, to exactly what the — we're sending the data we're storing natively in memory, we're just shoving those bytes right out. And so now the last one is RDMA. I'll cover what that is in a second. Basically this is like a network accelerator to do kernel bypass, to literally get the data out of memory, put it on the NIC, and send it out without having to copy things into the CPU first. And I forget, we used I think we used InfiniBand for this one. But again this one also is just sending out native Arrow blocks rather than doing the conversion.

So again, even though the paper you guys read didn't implement — didn't have Arrow at the time to send data out, the performance difference I think would look like this. So again, what I'm saying is that ADBC, just shoving data out as Arrow, is the right way to go if you're building a modern system today.

Yes. Is there a cost to convert whatever Postgres is into Arrow? Yeah, I mean certainly. Yes. Doesn't that 15 like that shows the cost of to whatever format? No, this is the cost of converting Arrow into a post compatible protocol that sends things in a vectorized format. This is like I don't do any copying, I just literally shove the bytes out. And the paper talks about to do something like this, to rewrite your wire protocol, it'd be very unlikely that you're storing that data natively anyway, so if you just have things convert things to Arrow or have things already be Arrow internally, then that's a better way to do this. That's why you see some systems, like the intermediate results going from one operator to the next, the query planner, how they exchange data between the different workers. If everything's Arrow, then you have the infrastructure to shove the data like that.

Okay. So in these experiments showed here, we talked about how the network protocol — do you compress things, how you encoding, the serialization format, how much metadata you're sending around — that was what we focused on, but that isn't always going to be the major slowdown of sending things over the network. Right. And as I said many times, the OS is going to be a problem for us. It's always going to try to ruin our lives, make things harder for us, break up our marriages and whatever. Right. And in particular, TCP/IP is just going to be super slow. And ideally we want to try to avoid it. So why is it slow? Well, the networking implementation is based on this model of interrupts. So they're requiring, they're assuming these interrupts are going to come along, and that's how it's going to trigger things like hey, bytes are ready to go in and out. And that's — you do a context switch, like all that becomes super expensive. Then you get data coming on the NIC, the OS wants to copy that in its own internal kernel buffers, and then before it hands you that memory, it's going to copy into your user space buffers. Right. What's that phase? What's that? What's wrong? Sorry? Yeah, this sucks. Yeah, this is terrible.

Furthermore, the kernel has got a bunch of threads coming down and they're handling the interrupts, they're handling things coming over the NICs and hardware and so forth. Well those have to be scheduled, they have to maintain their own latches for their own internal data structures. All that is going to be problematic. Right. So we want to figure out a way that we can avoid the OS as much as possible. Yeah, we need the OS to survive, we need it to give us some memory and obviously schedule us, but after that we want to avoid it as much as possible. And that's going to allow us to run faster. So what I'll talk about next is going to be focusing primarily on networking stuff, but this also applies for disks. You want to avoid the OS for disks as much as possible too.

All right. So the first approach to what I will call kernel bypass, and the idea here is that we want to be able to get data directly from the hardware, in this case the NIC, the network interface, we want to get that into our database system running in user space, into our memory up there, without having to go through the OS, without doing any copying, ideally without having to talk to the OS TCP/IP stack. And so there's three different ways you can do this. There's DPDK, RDMA, and then io_uring is going to be the newer one.

Right. So the way to think about this is the OS — Linux is a time sharing system — and that means it's going to rely on these slow expensive interrupts to again tell it when something new is showing up and take away executing some thread to go let the kernel thread deal with whatever that interrupt handler is. Right. And all these additional threads on the inside, they're going to maintain their own latches, and all those things are going to be problematic for us. Now Linux has gotten a lot better in the last 10 years. Over the 10 years it's gotten way better for handling large core counts. It's got way more scalable than it used to be, but you know whenever there's contention, no matter how great your code is, everything's always going to fall over. Want to avoid as much as possible.

All right. So let's go through these one by one. So the DPDK, the Data Plane Development Kit, this is from Intel. So it's a set of libraries that allow your user space program to interact with the NIC directly. There's an equivalent for in the storage world called the SPDK, the Storage Plane Development Kit, also from Intel. And the idea here is that you treat whatever the hardware device you're trying to interact with as a raw device, meaning you're responsible for reading the low-level bits in the memory space of that device and interacting with it. And this goes against the Unix philosophy where everything's a file, right, no matter what. We have to implement the TCP/IP stack for you on the device. We have to do that in our database system. So you either write it by hand or you can use an open source library like F-Stack that basically reimplements in user space TCP/IP — sending the sequence numbers, sending back ACKs, like all that we have to do ourselves. The OS isn't going to do this, and the hardware doesn't do it. But the advantage is that we don't have any data copying because we're now getting literally raw buffers of packets. We have to manage what those are off the — we're not calling read. Excuse me, there's no syscalls. Everything is done again reading directly into memory.

So this sounds amazing, right. Well it's not that common. As far as we know, there's only two systems that actually implement or use DPDK. The first is ScyllaDB and they have this framework called Seastar that they built on top of. Scylla is a reimplementation of Apache Cassandra in C++ with like fibers and DPDK and some other optimizations, where Cassandra is entirely in Java. And then Yellowbrick will cover later on, they also use this as well. But the ScyllaDB guys gave a talk with us a few years ago during the pandemic and they mentioned how in the sea — like yes they use DPDK, but DPDK for them has been a total nightmare to deal with, and I think it's turned off by default at this point. I saw the Yellowbrick CTO a few weeks ago at CIDR and as far as I know they're still using DPDK for their implementation. Again, they're doing this though in the back end, not between the client and the server.

Right. Why is it so hard? Well again, because you have to implement a bunch of stuff that OS normally do for you. You have to implement yourself. And we tried this in our system. We had one of my best master students try to use F-Stack to speed up something in another project we were doing, to make a Postgres proxy run faster, and we just could — we couldn't make it work. The engineering cost is just way too high. So to — it's a bit crude, but this is one of my favorite tweets of all time. So this guy's talking about the SPDK, which again that's for the storage plane data kit, but the DPDK certainly applies here. Right. So all this kernel bypass stuff is fantastic. You think you're going to get a big win, but it's like peeing your pants because you're cold and then you regret it pretty quickly.

This is the guy who wrote io_uring? Is it? Yeah, okay. Thank you.

Okay. All right. So the next approach is RDMA and this is where you have an API that the hardware provides that allows you to read write directly into the hardware device and to access things on a remote machine as if it was local. For this one it's a bit more tricky because now if you're reading writing to memory addresses on a remote machine, you got to be sure that what you're actually reading is what you expect to read. So there is more handshaking you have to do to set this up. So this typically again something you maybe want to use on the back end. If you can pull this off, then you get a huge win. So it used to be you only do this on InfiniBand, which was sold by Mellanox. I think Nvidia bought Mellanox recently or at some point. Yes. Nvidia uses — yeah they have NVLink as well. But RoCE is basically RDMA over Converged Ethernet or something, this is more common now.

So RDMA is not used that often. The only system I know that does this and will sell it to you is Oracle for Exadata. But again that's like you buy the whole — you buy the rack of compute and the rack of storage and they're using RDMA to communicate between the compute and the storage. You can get RDMA on Amazon, but again you would only be able to do the communication between your own machines that had that, and it's a lot more work to get that set up.

Yes. So how this works basically is that the client knows exactly what address the data is stored on the server, so it just says give me 0x1024. Is that statement correct? Like the way this works is that the client — or doesn't have to be, again the application could just be the thing that is going to talk to some other machine — has to know what memory address it wants to read, assuming it has permissions, and then the request is give me the contents of that memory. So the hardware knows how to go up to memory, get whatever you want, and pull it back down, and it doesn't notify the CPU that it's done that.

Yes. Is that a security problem with this? The question is, is there a security problem for this? Sure, but you run this in your VPC. You're not exposing this over the public internet. Again, if you're buying Exadata, these things are like millions of dollars. You're running this on-prem. It's a locked cage. The traffic is just between these two things.

All right. So the last one is io_uring, which I think some of you guys are familiar with. But this was an extension to Linux to clean up their asynchronous AIO API that allows you to do asynchronous requests to a hardware device, either storage or networking. It was originally storage and then they added networking two years ago. Basically the idea is that you have these circular buffers where you submit a request and say I want this data from this storage device or this hardware device, then you get a callback — you provide it to say okay when it's available in my buffer, let me know. So you can make a bunch of these requests. I don't think it's entirely bypassing the kernel, it's just less — you're not paying the overhead of making the syscall to block and wait for the data. Right. So you make the request to do whatever it is, to read or write, on the memory that you provide. The OS does it for you in a kernel thread, and then once it completes the task you asked to do, it puts the result in a queue and then gives you a callback. Right. So again a low latency way to avoid the overhead of a full syscall to talk to a hardware device, but you're still relying on the OS to do the low level marshalling of data on and off the device.

Yes. Correct me but I thought there was no callback. I thought you just check the completion queue. The library offers four different ways to do it. So you can either be polling — keep checking — or you can also block if you want to. You can also have — and there's many of these libraries, for those of you looking in Rust, there's one in Linux or in C++. They provide different programming APIs. I don't know which one's the most common. That was the one I saw.

So as far as I know, very few systems do this. Although you guys — well there's two more. Yeah. The first one is QuestDB. So they talked about in 2022 how they added io_uring. And QuestDB — the top part of it is Java and they use JNI to call down C++ code. TigerBeetle is another one, and they're using io_uring. But this is for transactional stuff. This is actually written in Zig, not Rust. And so I think there's some library in Zig that made this easier for them to do. But huh, it's in Zig. Yeah. And we talked to somebody recently or yesterday who was like, yeah they used FastLanes and Zig because the SIMD stuff was way better than Rust.

The interesting one though is ClickHouse. So they came out with a blog article in 2021 about hey, they're adding io_uring and asynchronous IO to ClickHouse. I said there is — we had a guy give a talk from the Postgres team about adding io_uring to Postgres, but that's going to be I think years away because they're rewriting the whole storage layer in Postgres and I think they're finally going to get rid of the OS page cache, which is nice. So there's this blog article that talks about like hey, look here's what io_uring can do for us. It's going to be a big win. He submitted the pull request. Then when you go look at the pull request, lo and behold you come down here and here's one of the original developers of ClickHouse and current CTO. He basically says, yeah he tried adding it but it was marginal improvement and it became an engineering nightmare. Right. He says it became so complicated that even an experienced C++ engineer, the author of the code, cannot figure out why there are rare hangs of queries. Right. They found that through their testing. So that was — the blog article is 2021. This post is 2022. But then in the release of ClickHouse in February 2023, here's the same dude giving a live stream talking about how they've now added io_urings, they did end up merging this code, and they're touting how it's the magic pill to make IO less slow. Right. In his webinar. But then you go look at the pull request again, and this is just a few weeks ago, a few months ago, he's posting here: "I didn't observe io_uring to be much slower, but also I have no big expectations because I wasn't able to find cases when it's faster." Because he's responding to somebody up above that talks about how io_uring when you enable that makes his queries slower.

So I think — all of these systems, none of them are asynchronous. They're all built to be synchronous, blocking. The rest of the framework is not — the query execution code itself is blocking, blocking. Yes. So like how would they ever get any performance other than just batching? Systems like batching. And yeah, and then like you — I need to read these 10 blocks, go batch a bunch of stuff, go process the ones that are available, and then in the background when it's available I can process it. I think that's the only thing that they could benefit out of. I think that's what they're doing. I don't know about QuestDB. QuestDB is like written by HFT guys out of London, and those dudes all sorts of — like they know how to make Java work really fast. I just don't know how they implemented theirs.

Using mmap and then they switched it to be faster? Yes. So they have a crappy mmap implementation and then they're like — okay it's basically like if I chop my leg off and I can barely walk but I sew the leg back on now I can walk. Like it's yeah. Got it.

Okay. All right. So I think I don't want to comment. I think the jury is still out. I think that this is still pretty bleeding edge, but interesting to see what you guys come up with.

All right. So I want to quickly talk about two last things. So these are all sort of kernel bypass methods. But there's another alternative: instead of trying to avoid talking to the kernel, what if we put things in the kernel that we would want, right, to avoid copying up into user space. So let me skip this. So this is a technique called user bypass. It's not a new idea. People have done kernel modules and extensible OS kernels for decades. What makes it different now — we'll see in the next slide — but the idea here is that instead of trying to bypass this part here and pull a bunch of this logic up into the database system, what if you can put database system logic down in the kernel? And so that when data comes in, we can process it or do whatever you want on it as quickly as possible without having to copy to user space, and then if necessary go back down to the hardware to send things back immediately.

So this makes sense when the data that's coming in with the network or whatever it is doesn't need to be retained for a long time. If it's a say acknowledgement message and I need to keep track that I got it and I don't need to retain it, then this technique potentially would work. Right. Because you avoid all the overhead of copying buffers, of scheduling additional threads, and making system calls, because everything now is just running inside the kernel, which is always going to be faster.

So as I said, kernel modules are one way to do this, but if you've ever written a kernel module before, you know — it's a pain in the ass. It's super cumbersome. If you crash, what do you get? Kernel panic. You take everything down. And then in some scenarios you can't even load kernel modules for security reasons — the hardware won't let you load an unsigned kernel module. Right.

So the thing that has changed that makes this actually viable now is something called eBPF. A curiosity: who here has heard of eBPF before? Well other than people that hang out with my student Matt. Right. So BPF — eBPF — BPF stands for Berkeley Packet Filter. So in the early 90s they had made it for BSD, eventually made it into Linux, but it was a way to specify packet forwarding rules and filtering rules through a DSL you then load into the kernel. Right. And so eBPF is not really about packet filtering anymore, but it's basically a way to write safe code that then gets verified and then load that dynamically as if it was a kernel module on the fly. And the reason why I'm saying safe is that they give you a limited API for what you're actually allowed to do in these kernel module programs that you're running. Right. So you can't call malloc, you can't sit in an infinite loop forever, right, because they're trying to avoid you from taking down the kernel and breaking everything. So you write your code, your eBPF program in C code, you run it through their compiler that generates bytecode that then runs through a verifier. It literally does basically branch expansion. It figures out all the different possible paths you could go down in your code and counts the number of instructions that you would execute, and then throws an error and rejects it if you have too many instructions. Right. So this is a wild thing because again this basically allows you to extend Linux without having to recompile Linux. So this is heavily used by Netflix for observability, to be able to get metrics about what processes are running and get this data out. But as the API has expanded since Matt's been working on it here, there's a lot more things you can start doing now. You can basically run entire database system logic down in your kernel. Whether or not that's a good idea or not, that's what his research is going to figure out. But the idea is that can we start thinking about what part of the data system that we're spending a lot of time on moving data back and forth between the OS and the hardware and the database system — what can we start pushing down?

So I'm going to show one graph from his paper where he was reimplementing the Postgres wire protocol proxy. So I think a proxy would sit in front of Postgres — the client connects to it and the proxy maintains available connections to the database system and just forwards your packets along. So in this scenario, a packet shows up to send a query request, and the proxy just looks at it, says oh it needs to go to this server, and just sends it. That's all it's really doing. It's not doing any computation on it. So we're comparing it to PgBouncer, which is the most common proxy implementation used for Postgres. Odyssey is out of Yandex. And this is like doing — all this runs in user space, but they're using handwritten coroutines written in assembly where the assembly overwrites the stacks of other threads to inject what the next thread to run. It's very impressive, but it's very complicated. And then ARS is — it's a fork of PgBouncer where all of the authentication stuff happens up in the user space — SSL setup and things like that, user password stuff all happens up there — but then when packets show up, all that is done down in eBPF.

So the main takeaway here is if you run on a really small machine, you're getting pretty significant performance improvement because you're not paying the penalty of copying things back and forth between the kernel. So I'm not saying eBPF can solve all the things that we talked about today, but I think this is going to be a better solution than something like DPDK and potentially io_uring for somethings, but not everything.

All right. Got one minute left, so let me just bang through this really quickly. So once we do all the optimizations to get things out of the server back to the client, the client's got to do something with it and put it into the form that the application needs. And I said if it's JDBC, ODBC, like that's copying things as a row oriented format, that's — the overhead is not going to be that significant. But if it's the scenario where it's a data scientist trying to get things out of the database system and put it into Pandas, then that's going to be slow. So this here — this from an experiment they did where they took Pandas, ran a SQL query through Pandas' SQL API that went to Postgres, MySQL, got data back, and then converted into a DataFrame. DataFrame is like the table abstraction in Pandas and a bunch of other Python systems. So in this case, the chart showing that the query part is not that — it's not going to take a long time relative to all the cost of actually copying the data off the bits we've got from the server and converting it into the DataFrame. Again, ADBC with Arrow solves this problem because if you're Python code can natively operate on Arrow data, then you don't have to do this conversion. But if your system doesn't support ADBC like MySQL, then you have to pay this penalty.

So the gist of what they're doing is that they have this thing called ConnectorX. It is using Postgres and a couple other systems I think as well, like MySQL. And basically your SQL query that you write in Python — you also provide some information on how to split that query up into subqueries or partition queries, like range partitioning, and then you send out multiple queries at the same time from different threads that are going to get a portion of the data that you would want to put into your Python program. And then each thread is going to populate the DataFrame at different chunks. So instead of taking one single query, getting back a giant result, and one thread populating the table, they take one single query, rewrite it by adding like additional expressions in the WHERE clause, then send that out in parallel, get back multiple results, and the threads put it together. I just want to bring this up because it's an alternative. If you don't have ADBC, this is another approach to do this.

All right. We're well over time, so I apologize. All right. So networking protocol matters a lot. Kernel bypass can make a big difference but it's a pain in the ass to use. I think eBPF is going to get a lot more uptake in the next 10 years or so, as eBPF gets more expressive. Okay. So next class will be on query optimization, and we'll have three lectures on that, and that'll be again the core material we need to understand before we start looking at other relations. And I know I haven't posted the updated reading list because I don't know what paper to read for the first class, because there really isn't a good one. But we'll figure something out. I'll update the reading list tonight.

Okay. Any questions?