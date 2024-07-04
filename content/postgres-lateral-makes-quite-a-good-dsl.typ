#import "/templates/post.typ": post

#let args = (
  title: "Postgres's lateral joins allow for quite the good eDSL",
  date: "2026-03-15",
  slug: "postgres-lateral-makes-quite-a-good-dsl",
  tags: ("programming", "rust", "postgres", "edsl"),
  summary: "Lateral joins are quite neat and you can build a query eDSL with them.",
)

#show: post.with(..args)

Postgres (and a few other databases(?)) has a lesser known or used join type
known as the lateral join. They allow columns from preceding FROM clauses to be
used in subqueries that are being joined.

As a (bad) example, take this pretty standard query joining two tables:

```sql
SELECT *
FROM users u
INNER JOIN posts p ON u.id = p.user_id
```

This can be rewritten as a lateral join with:

```sql
SELECT *
FROM users u
CROSS JOIN LATERAL (select * from posts p where u.id = p.user_id) p2
```

Notice that the join type changed to `CROSS`, normally this would result in a
cartesian product, but the filter inside the subquery means each post is still
paired up only with its user.

In fact, both queries actually get the same query plan:

```
+----------------------------------------------------------------+
| QUERY PLAN                                                     |
|----------------------------------------------------------------|
| Hash Join  (cost=37.00..60.52 rows=1070 width=88)              |
| Hash Cond: (p.user_id = u.id)                                  |
| ->  Seq Scan on posts p  (cost=0.00..20.70 rows=1070 width=48) |
| ->  Hash  (cost=22.00..22.00 rows=1200 width=40)               |
| ->  Seq Scan on users u  (cost=0.00..22.00 rows=1200 width=40) |
+----------------------------------------------------------------+
```

This is actually really useful as it provides a way to solve an expressivity
problem that I think most ORMs and query builders have: that queries are
difficult to compose.

I think most composition techniques in other query builders boil down to either
passing some query builder object through a sequence of functions, each of which
appends a table to be joined and a where clause, or having functions that return
subqueries which you then have to handle joining with your query yourself.

Neither of these are very good, the first way probably only works in dynamically
typed languages, and in the latter you lack any way to provide a
`posts_of_users(user_id) -> [Post]` 'function'.

Worst of all IMO are ORMs which abstract away relationships. It's cool at first
to be able to write `select(User).with(Post)` and have it build the join
automatically, or even handle a M2M join. But as soon as you need to update
something it becomes even more tedious than managing the join table yourself,
I've witnessed before the need to first load all values before you can add or
remove an entry using the normal interface, lest you accidentally instruct the
ORM to delete all entries before inserting yours, or try to create duplicates on
one side of a M2M.

Also any ORM with some `.with()` method is going to be hell in a typed language,
it either needs to use some macro magic to summon types such as `FooWithBar` for
every possible combination, or maybe it produces some `With<Foo, bar>` type that
results in some horrible types `With<With<Foo, Bar>, Baz>` that are impossible
to work with without IDE assistance.

I'm also not much of a fan of the 'generate bindings' approach of writing plain
SQL queries (either in their own files, or inline) and using some compile time
code execution to generate functions for the host language to use (e.g. sqlx).
With these you're back to writing SQL, but at least you have type safety.
Also this is strictly less composable than any other form of building queries.

I want to present a type of query builder library that is all of:

+ Expressive: Queries doing complicated joins shouldn't be inscrutable, ideally
  such a query should be clearer represented in the eDSL than in SQL
+ Composable: Queries should be reusable, and parameterisable
+ Type safe: The eDSL works within the type system of the host language to
  ensure queries are correctly typed
+ Always generates valid SQL: This is particularly useful when it comes to
  aggregations, as using an aggregate operator changes the requirements of the
  entire part of the query it is used in
+ Works with user types: I think this is one of the draws to using ORMs, in
  that they handle the boilerplate of making user types work with the database.

The first library I've encountered that provides a way to build queries
compositionally using lateral joins is the Haskell library
#link("https://rel8.readthedocs.io/en/latest/")[Rel8], and it looks like this:

```haskell
postsForUser :: Expr UserId -> Query (Post Expr)
postsForUser userId = do
  post <- each postSchema
  where_ $ post.userId ==. userId
  pure post

usersAndPosts :: Query (User Expr, Post Expr)
usersAndPosts = do
  user <- each userSchema
  post <- postsForUser user.id
  pure (user, post)
```

This interface is extremely expressive to the point that it feels like you're
actually just manipulating data that is already in the host language, but in
actuality you're building a sql query that will look something like this:

```sql
SELECT
CAST("id0_1" AS "int4") as "_1/id",
CAST("name1_1" AS "bpchar"(1)[]) as "_1/name",
CAST("id0_3" AS "int4") as "_2/id",
CAST("user_id1_3" AS "int4") as "_2/userId",
CAST("body2_3" AS "bpchar"(1)[]) as "_2/body"
FROM (SELECT
      *
      FROM (SELECT
            "id" as "id0_1",
            "name" as "name1_1"
            FROM "user" AS "T1") AS "T1",
      LATERAL
           (SELECT
            "id" as "id0_3",
            "user_id" as "user_id1_3",
            "body" as "body2_3"
            FROM "post" AS "T1") AS "T2"
      WHERE (("user_id1_3") = ("id0_1"))) AS "T1"
```

The trick is that `Expr UserId` doesn't contain any `UserId`, but instead
contains (in this case) the SQL expression `id0_1`, which can then in
`postsForUser` be used as if it were any other SQL expression such as a literal.

A `Query` is then just a `SELECT ...` clause, and each line of the `do` block
introducing a query adds a `CROSS JOIN LATERAL ...`, and a `where_` just
introduces a `WHERE` into the query being built.

Now this does of course have one glaring issue: `id0_1` is only valid when used
inside a sibling subquery of the subquery introducing the `*_1` columns, which is also
syntactically positioned afterwards. And usually in query builders we want to
make it reasonably difficult to generate invalid queries, as debugging those is
always a royal pain.

In Haskell this is actually solved inherently: the `Expr` values are only ever
available 'inside' the `Query` monad. There is no way to get an `Expr` 'out' of
it and therefore any `Expr` can only be used after it has been introduced, and
only in a scope equal to (within the same `Query`) or deeper than (within some
`Query` created by calling a function) that in which it was introduced.

Now I'm going to stop talking about Haskell here, because what I would actually
like to talk about is the Rust library I wrote which replicates the behaviour of
Rel8, which I will call #link("https://github.com/simmsb/rust-rel8")[rust-rel8] until
I can think of a catchy project name.

My library looks pretty much just like Rel8, but in rust:

```rust
fn posts_of_user(user_id: Expr<i32>) -> Query<Post> {
    query::<Post<ExprMode>>(|q| {
        let post = q.q(Query::each(&Post::SCHEMA));
        q.where_(user_id.equals(post.user_id.clone()));
        post
    })
}

let q = query::<(User<ExprMode>, Post<ExprMode>)>(|q| {
    let user = q.q(Query::each(&User::SCHEMA));
    let post = q.q(posts_of_user(user.id.clone()));

    (user, post)
})
.order_by(|x| (x.clone(), sea_query::Order::Asc));

let rows = q.all(&mut *pool).await.unwrap();
```

You can even do cool things such as aggregating the result of `posts_of_user`,
so that the result is `(User, Vec<Post>)` as it comes out of the database:

```rust
let q = query::<(User<ExprMode>, ListTable<Post<ExprMode>>)>(|q| {
    let user = q.q(Query::each(&User::SCHEMA));
    let posts = q.q(posts_of_user(user.id.clone()).many());
    // that .many() turns a Query<T> into Query<ListTable<T>>

    (user, posts)
})
.order_by(|x| (x.0.name.clone(), sea_query::Order::Asc));

let rows: Vec<(User, Vec<Post>)> = q.all(&mut *pool).await.unwrap();
```

Even cooler, a left outer join is made using `.optional()`:

```rust
fn latest_post_of_user(user_id: Expr<i32>) -> Query<MaybeTable<Post>> {
    query::<Post<ExprMode>>(|q| {
        let post = q.q(Query::each(&Post::SCHEMA));
        q.where_(user_id.equals(post.user_id.clone()));
        post
    })
    .order_by(|x| (x.id.clone(), sea_query::Order::Desc))
    .limit(1)
    .optional()
}

let q = query::<(Expr<String>, Expr<Option<String>>)>(|q| {
    let user = q.q(Query::values(demo_users.shorten_lifetime()));
    let post = q.q(latest_post_of_user(user.id.clone()));
    // `post` here is `MaybeTable<Post>`, we can either project an `Expr<Option<T>>` out of it,
    // or we could also just return it from the query, which would give us `Option<T>`
    // after decoding the result.
    let post_content = post.project(|p| p.contents.clone());

    (user.name, post_content)
})
.order_by(|x| (x.clone(), sea_query::Order::Asc));

let rows = q.all(&mut *pool).await.unwrap();

assert_eq!(
    vec![
        ("Huldra".to_owned(), None),
        ("Leschy".to_owned(), Some("Quak!".to_owned())),
        ("Undine".to_owned(), Some("Croak".to_owned()))
    ],
    rows
)
```

You can even declare your own tables:

```rust
#[derive(Debug, PartialEq, rust_rel8_derive::TableStruct)]
struct User<'scope, Mode: TableMode = ExprMode> {
    id: Mode::T<'scope, i32>,
    name: Mode::T<'scope, String>,
}

impl<'scope> User<'scope, NameMode> {
    const SCHEMA: TableSchema<Self> = TableSchema {
        name: "users",
        columns: User {
            id: "id",
            name: "name",
        },
    };
}

#[derive(Debug, PartialEq, rust_rel8_derive::TableStruct)]
struct Post<'scope, Mode: TableMode = ExprMode> {
    id: Mode::T<'scope, i32>,
    user_id: Mode::T<'scope, i32>,
    body: Mode::T<'scope, String>,
}

impl<'scope> Post<'scope, NameMode> {
    const SCHEMA: TableSchema<Self> = TableSchema {
        name: "posts",
        columns: Post {
            id: "id",
            user_id: "user_id",
            body: "body",
        },
    };
}
```

The `.aggregate` builder also is designed so you can build aggregations without the pain normally encountered when constructing them in SQL:

```rust
let q = query::<Two<_, i32, i32>>(|q| {
    let a = q.q(Query::values([
        Two { a: 1, b: 1 },
        Two { a: 1, b: 2 },
        Two { a: 1, b: 3 },
        Two { a: 1, b: 4 },
        Two { a: 2, b: 1 },
        Two { a: 2, b: 2 },
        Two { a: 3, b: 1 },
    ]));
    a
})
.aggregate::<(Expr<i32>, ListTable<Expr<i32>>, ListTable<Two<_, i32, i32>>)>(|a, e| {
    let x = a.group_by(e.a.clone());
    let y = a.array_agg(e.a.clone().add(Expr::lit(1i32)));
    let as_array = a.array_agg(e);

    // .aggregate enforces that everything in the output must have passed through `a`,
    // and therefore must either be used as part of a group by or in an aggregation function.
    (x, y, as_array)
});

let rows = q.all(&mut *pool).await.unwrap();

assert_eq!(
    vec![
        (
            1,
            vec![2, 2, 2, 2],
            vec![
                Two { a: 1, b: 4 },
                Two { a: 1, b: 3 },
                Two { a: 1, b: 2 },
                Two { a: 1, b: 1 }
            ]
        ),
        (3, vec![4], vec![Two { a: 3, b: 1 }]),
        (2, vec![3, 3], vec![Two { a: 2, b: 2 }, Two { a: 2, b: 1 }])
    ],
    rows
);
```

The derive macro here is implementing a few traits needed by the library for it
to know how to visit each of the columns of your table, most of the magic is in
this `Mode::T<'scope, U>` ADT, which changes out the types of the fields with
`U`, `Expr<U>`, and `String` depending on the `TableMode`. This is what allows
us to use user types inside the eDSL, but also as outside with the resultant
values.

Naturally, being Rust it is some amount mode verbose than the Haskell
equivalent, but the actual api of Rel8 is reasonably easy converted to Rust.

How does this work? Let me explain:

First we need a type to represent scalar expressions, we'll call this `Expr`:

```rust
pub struct Expr<'scope, T> {
    expr: ExprInner,
    _phantom: PhantomData<(&'scope (), T)>,
}
```

`'scope` here is a lifetime used to enforce expression scoping rules, you can
ignore it for now and we'll get to it later. The `PhantomData` is needed because
`Expr` contains neither `T` or `'scope`.

`ExprInner` is simply a wrapper around the AST of the query builder library I'm
using underneath (sea\_orm), but it allows for traversing over references to
columns contained within.

This `Expr` then has a few methods corresponding to common SQL operations done
on scalars:

```rust
impl<'scope, T> Expr<'scope, T> {
    /// Construct a literal value from any value from any value that can be encoded.
    pub fn lit(value: T) -> Self
    where
        T: Into<sea_query::Value>,
    {
        Self::new(ExprInner::Raw(sea_query::Expr::value(value.into())))
    }

    fn binop<U>(
        self,
        other: Self,
        binop: Arc<dyn Fn(sea_query::SimpleExpr, sea_query::SimpleExpr) -> sea_query::SimpleExpr>,
    ) -> Expr<'scope, U> {
        Expr::new(ExprInner::BinOp(
            binop,
            Box::new(self.expr),
            Box::new(other.expr),
        ))
    }

    /// SQL equality
    pub fn equals(self, other: Self) -> Expr<'scope, bool> {
        self.binop(
            other,
            Arc::new(|a, b| a.binary(sea_query::BinOper::Equal, b)),
        )
    }

    /// SQL numeric addition
    pub fn add(self, other: Self) -> Self {
        self.binop(other, Arc::new(|a, b| a.binary(sea_query::BinOper::Add, b)))
    }

    /// generate `nextval('name')`
    /// for it to behave properly.
    pub fn nextval(name: &str) -> Self {
        Self::new(ExprInner::Raw(
            sea_query::Func::cust("nextval").arg(name.to_owned()).into(),
        ))
    }
}
```

Then to represent a query we have `Query`:

```rust
/// A value representing a sql select statement which produces rows of type `T`.
#[derive(Clone)]
pub struct Query<T> {
    // Unique ID used to make the table name and columns unique
    binder: Binder,
    expr: sea_query::SelectStatement,
    inner: T,
    siblings_need_random: bool,
}
```

This isn't itself very interesting as it actually only contains the AST of a
select statement and an expression so the library can know the columns produced
by the query, the magic happens in `query`:

```rust
pub struct Q<'scope> {
    queries: Vec<(TableName, ErasedQuery)>,
    filters: Vec<ExprInner>,
    binder: Binder,
    _phantom: PhantomData<&'scope ()>,
}

impl<'scope> Q<'scope> {
    pub fn q<T: ForLifetimeTable + Table>(&mut self, query: Query<T>) -> T::WithLt<'scope> {
        let binder = Binder::new();
        let name = TableName::new(binder);
        let (erased, mut inner) = query.erased();
        self.queries.push((name.clone(), erased));
        insert_table_name(&mut inner, name);
        inner.with_lt(&mut WithLtMarker {})
    }

    pub fn where_<'a>(&mut self, expr: Expr<'a, bool>)
    where
        'scope: 'a,
    {
        self.filters.push(expr.expr);
    }
}

pub fn query<'outer, T: ForLifetimeTable + Table + 'outer>(
    f: impl for<'scope> FnOnce(&mut Q<'scope>) -> T::WithLt<'scope>,
) -> Query<T> {
    let mut q = Q {
        binder: Binder::new(),
        filters: Vec::new(),
        queries: Vec::new(),
        _phantom: PhantomData,
    };

    let mut e = f(&mut q);

    let mut iter = q.queries.into_iter();
    let mut table = sea_query::Query::select();

    // the first query becomes the 'main' query of the SELECT
    if let Some((first_table_name, first)) = iter.next() {
        table.from_subquery(first.expr, first_table_name);
    };

    // lateral join on all the remaining
    for (table_name, q) in iter {
        table.join_lateral(
            // normally a cross join, but sea_query doesn't support omitting the `ON` for cross joins (:
            // and CROSS JOIN is INNER JOIN ON TRUE
            sea_query::JoinType::InnerJoin,
            expr,
            table_name,
            sea_query::Condition::all(),
        );
    }

    for filter in q.filters {
        table.and_where(filter.render());
    }

    // the query currently selects no columns, this function traverses the expressions within
    // the output table, adding each expression to the SELECT in the form `<expr> AS <name>`,
    // then replaces the expression within with the `<name>` column reference.
    subst_table(&mut e, TableName::new(q.binder), &mut table);

    let e = ForLifetimeTable::unwith_lt(e, &mut WithLtMarker {});
    Query::new(q.binder, table.to_owned(), e)
}
```

There's not actually much going on here, all we really have to do is ensure
we're renaming columns correctly as to not cause collisions, otherwise all we do
is start with the first query mentioned, insert a lateral join for each
subquery, and then traverse through the columns in the result table to insert
them as the projected columns of the query we're building.

You probably saw the type signature of `query` (and everything having a
`'scope'` lifetime parameter), it's doing a lot and the reason is that I was
able to use the borrow checker to enforce the scoping rules of queries.

The type of the callback has `for <'scope>'`, which means that the passed
function must be generic over that lifetime, and cannot know anything about the
lifetime other than it is given some `Q<'scope>` and must return some `T` with
that lifetime.

However once `query` has processed the query, the lifetime is swapped out with
`'outer`, which being a lifetime parameter of `query` means the user gets to
choose which this is. This makes sense, a `Query` is a standalone and complete
`SELECT` query which can be executed on the database, so there's no need for any
lifetime tracking.

Ideally it should render to `'static` instead, but there's an unfortunate
consequence of using this lifetime parameterised `WithLt<'lt>` GAT: It is
invariant in `'lt` and therefore `YourTable<'static>` cannot have its lifetime
shortened (even though it is morally equivalent to `&'static YourTable`). So I
chose to have `query` be generic in the `'outer` lifetime so that users don't
have to do tons of manual lifetime shortening (more on that soon).

One slightly unfortunate fact about `T` appearing as `T::WithLt<...>` in the
callback of `query` is that it results in rust not being able to infer `T` from
its usage, the user must always spell it out somewhere (fortunately the user
doesn't have to name the lifetimes). In a perfect world we would be able to
write `fn query<'outer, T: for<'a> (T<'a>: Table), F: FnOnce(...) -> T<'scope>>(...) -> T<'outer>` such that rust would be able to see that the `T`
returned from the closure is the same as the `T` returned from `query`. But this
is not a perfect world.

Now this function needs to be generic over all possible tables (a 'table' being
either a singleton `Expr<T>`, a tuple `(T, ...) where T: Table`, or a user
defined table). We also don't want to have an API which is overly restrictive
(We could have tables be some `Table<(i32, UserType)>`, but this would deny the
use of standard field access to project out sub-tables and columns). This means
we need some traits to model the operations the library needs to be able to
perform, which are:

- Visiting the columns within a table: `trait Table`.
- Changing the lifetimes within a table: `trait ForLifetimeTable`.
- A way to permit shortening a lifetime of a table: `trait ShortenLifetime`.
- Changing the mode of user tables: `trait TableHKT`.
- A way to apply a natural transformation to the fields of a user defined table: `trait MapTable`.

`Table` is very simple, all it represents is how to run some callback over all
the columns within a table. For `Expr<T>` it is just calling the callback on the
internal `ErasedExpr`, for tuples: calling visit on each sub-table in turn.

```rust
pub trait Table {
    /// The value a row of this table has when loaded from the database.
    type Result;

    /// Visit each expr in the table.
    ///
    /// The order and number of expressions visited must always remain the same,
    /// across: [Table::visit], [Table::visit_mut], and all methods of [MapTable].
    fn visit(&self, f: &mut impl FnMut(&ErasedExpr), mode: VisitTableMode);

    /// Visit each expr in the table, with a mutable reference.
    ///
    /// The order and number of expressions visited must always remain the same,
    /// across: [Table::visit], [Table::visit_mut], and all methods of [MapTable].
    fn visit_mut(&mut self, f: &mut impl FnMut(&mut ErasedExpr), mode: VisitTableMode);
}
```

`ForLifetimeTable` allows the library to replace the lifetimes of nested
`Expr<'scope, T>` types within the table:

```rust
pub trait ForLifetimeTable {
    /// Substitute the lifetime of this table with `'lt`.
    type WithLt<'lt>: ForLifetimeTable + Table + Sized;

    fn with_lt<'lt>(self, marker: &mut WithLtMarker) -> Self::WithLt<'lt>;
}

impl<'scope, T: Value> ForLifetimeTable for Expr<'scope, T> {
    type WithLt<'lt> = Expr<'lt, T>;

    fn with_lt<'lt>(self, _marker: &mut WithLtMarker) -> Self::WithLt<'lt> {
        Expr::new(self.expr)
    }
}
```

`ShortenLifetime` is similar to `ForLifetimeTable`, but its purpose is to be
used by users of the library when they need to shorten a lifetime of a table.

Normally rust does this automatically, but for tables the lifetimes are
invariant and therefore rust won't do it automatically. Instead the user has to
call `.shorten_lifetime()`.

```rust
pub trait ShortenLifetime {
    type Shortened<'small>
    where
        Self: 'small;

    fn shorten_lifetime<'small, 'large: 'small>(self) -> Self::Shortened<'small>
    where
        Self: 'large;
}

impl<'scope, T> ShortenLifetime for Expr<'scope, T> {
    type Shortened<'small>
        = Expr<'small, T>
    where
        Self: 'small;

    fn shorten_lifetime<'small, 'large: 'small>(self) -> Self::Shortened<'small>
    where
        Self: 'large,
    {
        Expr::new(self.expr)
    }
}
```

`TableHKT` allows the library to talk about user defined tables across different `TableMode`s:

```rust
pub trait TableHKT {
    /// The current mode of this table.
    type Mode: TableMode;

    /// Replace the mode with another.
    type InMode<Mode: TableMode>;
}

impl<'scope, T: TableMode> TableHKT for User<'scope, T> {
    type InMode<Mode: TableMode> = User<'scope, Mode>;
    type Mode = T;
}
```

And finally `MapTable`, which allows mapping the fields of a user defined type:

```rust
pub trait MapTable<'scope>: TableHKT {
    /// Map each field of the table
    ///
    /// The order and number of fields visited must always remain the same,
    /// across: [Table::visit], [Table::visit_mut], and all methods of [MapTable].
    fn map_modes<Mapper, DestMode>(self, mapper: &mut Mapper) -> Self::InMode<DestMode>
    where
        Mapper: ModeMapper<'scope, Self::Mode, DestMode>,
        DestMode: TableMode;

    /// Map each field of the table, with a reference
    ///
    /// The order and number of fields visited must always remain the same,
    /// across: [Table::visit], [Table::visit_mut], and all methods of [MapTable].
    fn map_modes_ref<Mapper, DestMode>(&self, mapper: &mut Mapper) -> Self::InMode<DestMode>
    where
        Mapper: ModeMapperRef<'scope, Self::Mode, DestMode>,
        DestMode: TableMode;

    /// Map each field of the table, with a mutable reference
    ///
    /// The order and number of fields visited must always remain the same,
    /// across: [Table::visit], [Table::visit_mut], and all methods of [MapTable].
    fn map_modes_mut<Mapper, DestMode>(&mut self, mapper: &mut Mapper) -> Self::InMode<DestMode>
    where
        Mapper: ModeMapperMut<'scope, Self::Mode, DestMode>,
        DestMode: TableMode;
}
```

`MapTable` is a fun one, but to understand it we first need to look at `TableMode` and user tables.

`TableMode` is a GAT trait whose purpose is to switch out some type depending on the mode:

```rust
pub trait TableMode {
    /// A Gat, the resultant type may or may not incorporate `V`.
    type T<'scope, V>;
}

impl TableMode for NameMode {
    /// a string representing the column name.
    type T<'scope, V> = &'static str;
}

impl TableMode for ValueMode {
    type T<'scope, V> = V;
}

impl TableMode for ValueManyMode {
    type T<'scope, V> = Vec<V>;
}

impl TableMode for ExprMode {
    type T<'scope, V> = Expr<'scope, V>;
}

impl TableMode for EmptyMode {
    type T<'scope, V> = ();
}
```

A user type is then defined as:

```rust
struct User<'scope, Mode: TableMode = ExprMode> {
    id: Mode::T<'scope, i32>,
    name: Mode::T<'scope, String>,
}
```

This means that `User<NameMode>` is `{ id: &str, name: &str }`, and when
in `ValueMode`: `{ id: i32, name: String }`. When used inside a query
the table will be in `ExprMode`: `{ id: Expr<i32>, name: Expr<String> }`, which
is how we make it possible to write `q.where_(user.id.equals(user_id))`.

Of course, this pattern does have one problem that needs to be solved: given
some `User<NameMode>`, how does the library visit all the fields to extract the
column names, and then somehow produce a `User<ExprMode>` that the user can use
inside a query? Ideally we want to do this without requiring that `User`
implements some endless number of traits with methods like `fn name_to_expr_mode(self) -> (Vec<String>, User<ExprMode>)` for all the possible
operations we might need to do.

The answer is that all this can be modelled by the `MapTable` trait, which
really just boils down to providing a way to call a type changing function on
all fields of a type with some state threaded through all the calls. In fact the
library uses `MapTable` to implement `Table` for user defined tables.

The method of `MapTable` that I'll examine is is `map_modes_ref`, which visits each
field via an immutable reference, and produces a new table in the destination mode.

```rust
fn map_modes_ref<Mapper, DestMode>(&self, mapper: &mut Mapper) -> Self::InMode<DestMode>
where
    Mapper: ModeMapperRef<'scope, Self::Mode, DestMode>,
    DestMode: TableMode;
```

All the work here is done by `ModeMapperMut`:

```rust
pub trait ModeMapperRef<'scope, SrcMode: TableMode, DestMode: TableMode> {
    /// Map from `SrcMode` to `DestMode`, taking the value as a reference
    fn map_mode_ref<V>(&mut self, src: &SrcMode::T<'scope, V>) -> DestMode::T<'scope, V>
    where
        V: Value;
}
```

For the user to implement `MapTable`, they simply need to just write the following impl:

```rust
impl<'scope, Mode: TableMode> MapTable<'scope> for MyTable<'scope, Mode> {
    fn map_modes_ref<Mapper, DestMode>(&self, mapper: &mut Mapper) -> Self::InMode<DestMode>
    where
        Mapper: ModeMapperRef<'scope, Self::Mode, DestMode>,
        DestMode: TableMode,
    {
        let id = mapper.map_mode_ref(&self.id);
        let name = mapper.map_mode_ref(&self.name);
        let age = mapper.map_mode_ref(&self.age);
        User { id, name, age }
    }
}
```

This technique is what allows the library to use `MapTable` to perform
field-type changing traversals of user defined types, we are effectively setting
up a proxy where the user impl calls methods that we choose but instantiated
with the field types known by the user.

On the library side, we can then write 'mappers' that look like this:

```rust
/// A mapper which reads the column names of a table in [NameMode] and adds them to a select,
/// then yields an expression referencing the column.
struct NameToExprMapper {
    binder: Binder,
    query: sea_query::SelectStatement,
}

impl<'scope> ModeMapperRef<'scope, NameMode, ExprMode> for NameToExprMapper {
    fn map_mode_ref<V>(
        &mut self,
        src: &<NameMode as TableMode>::T<'scope, V>,
    ) -> <ExprMode as TableMode>::T<'scope, V> {
        let col_name = ColumnName::new(self.binder, src.to_string());
        self.query
            .expr_as(sea_query::Expr::column(*src), col_name.clone());

        Expr::new(ExprInner::Column(TableName::new(self.binder), col_name))
    }
}

// This is then used by Query::each to extract out the field names
// and produce the ExprMode table.

impl<'scope, T> Query<T>
where
    T: MapTable<'scope> + TableHKT<Mode = NameMode>,
    T::InMode<ExprMode>: ForLifetimeTable + Table,
{
    /// Given a [TableSchema], build a query that selects all columns of every row.
    pub fn each(schema: &TableSchema<T>) -> Query<T::InMode<ExprMode>> {
        let binder = Binder::new();
        let mut query = sea_query::Query::select();
        query.from(schema.name);

        let mut mapper = NameToExprMapper { binder, query };

        let expr = schema.columns.map_modes_ref(&mut mapper);

        Query::new(binder, mapper.query, expr)
    }
}
```

With that, we have all the pieces needed to build a query eDSL:

- With `MapTable` we can extract the column names of a `NameMode` table to build
  an `ExprMode` table selecting them, and at the end after running the query on
  the database we can use it again to convert an `ExprMode` table to `ValueMode`
  by deserialising each corresponding value from each result row according to
  the concrete field type.
- With `TableHKT` and `ForLifetimeTable` we can provide functions which operate
  on arbitrary tables while preserving the restrictions enforced by Rust's lifetimes.
- With `Query`, `query`, and `Q` the user can combine queries together with much
  freedom, but if their code compiles they are guaranteed to have a valid query.
- With `Expr<T>` the user can build scalar expressions and even pass them to
  other functions returning queries.

There's still much more to do, but it was very nice to build this small crate
that provides quite a powerful abstraction but doesn't actually need so much
code.
