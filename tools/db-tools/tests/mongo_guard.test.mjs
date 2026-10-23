// Tests for lib/mongo-guard.js, evaluated the way mongosh evaluates it, in a context whose db, Collection,
// Database and Mongo are stand-ins for the shell's own classes. Run with `node --test`.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import vm from 'node:vm';

const lib = new URL('../lib/', import.meta.url);
const guardSource = readFileSync(new URL('mongo-guard.js', lib), 'utf8');
const safetySource = readFileSync(new URL('safety.sh', lib), 'utf8');

// The guard's own lists, read from its source, so the stand-ins carry exactly the methods it names.
const listFromSource = (name) =>
  vm.runInNewContext(`(${guardSource.match(new RegExp(`const ${name} = (\\{[\\s\\S]*?\\n\\});`))[1]})`);
const WRITES = listFromSource('DBTOOLS_WRITE_METHODS');
const DRIVER_WRITES = listFromSource('DBTOOLS_DRIVER_WRITE_METHODS');

class Cursor {
  constructor(docs) {
    this.docs = [...docs];
    this.applied = {};
  }
  limit(n) { this.applied.limit = n; return this; }
  skip(n) { this.applied.skip = n; return this; }
  maxTimeMS(n) { this.applied.maxTimeMS = n; return this; }
  hasNext() { return this.docs.length > 0; }
  next() { return this.docs.shift(); }
}

function shell({ docs = [], mongoLacks = [], noDriver = false } = {}) {
  const calls = [];
  const wrote = (owner, name) => function () { calls.push(`${owner}.${name}`); return 'wrote'; };

  class Collection {
    find(...args) { calls.push(['find', args]); return new Cursor(docs); }
    aggregate(pipeline, options) { calls.push(['aggregate', pipeline, options]); return new Cursor(docs); }
    countDocuments(filter, options) { calls.push(['countDocuments', filter, options]); return docs.length; }
    estimatedDocumentCount() { return docs.length; }
  }
  class Database {
    getCollection() { return new Collection(); }
    getMongo() { return mongo; }
    aggregate(pipeline, options) { calls.push(['db.aggregate', pipeline, options]); return new Cursor(docs); }
  }
  class Mongo {}
  class ServiceProvider {
    runCommandWithCheck() { calls.push('ServiceProvider.runCommandWithCheck'); return { ok: 1 }; }
  }
  class DriverCollection {}
  class DriverDb {
    collection() { return new DriverCollection(); }
    command() { calls.push('DriverDb.command'); return { ok: 1 }; }
  }
  class DriverClient {
    db() { return new DriverDb(); }
  }
  for (const name of WRITES.Collection) Collection.prototype[name] = wrote('Collection', name);
  for (const name of WRITES.Database) Database.prototype[name] = wrote('Database', name);
  for (const name of WRITES.Mongo) if (!mongoLacks.includes(name)) Mongo.prototype[name] = wrote('Mongo', name);
  const driverClasses = { ServiceProvider, DriverCollection, DriverDb, DriverClient };
  for (const [owner, names] of Object.entries(DRIVER_WRITES)) {
    for (const name of names) driverClasses[owner].prototype[name] = wrote(owner, name);
  }

  const mongo = new Mongo();
  if (!noDriver) {
    mongo._serviceProvider = new ServiceProvider();
    mongo._serviceProvider.mongoClient = new DriverClient();
  }
  const printed = [];
  const reported = [];
  const context = vm.createContext({
    db: new Database(),
    process: {
      env: { DBTOOLS_LIMIT: '3', DBTOOLS_SKIP: '0', DBTOOLS_MAX_TIME_MS: '600000' },
      stderr: { write: (text) => reported.push(text) },
    },
    print: (line) => printed.push(line),
    console: { error: () => assert.fail('console.error goes to stdout in mongosh; the summary must not use it') },
    EJSON: {
      stringify: (value, options) => {
        assert.deepEqual({ ...options }, { relaxed: true }); // spread: the object comes from the context's realm
        return JSON.stringify(value);
      },
    },
  });
  return { context, calls, printed, reported, Collection, Database, Mongo };
}

function guarded(options = {}, env = {}) {
  const s = shell(options);
  Object.assign(s.context.process.env, env);
  vm.runInContext(guardSource, s.context);
  s.run = (code) => vm.runInContext(code, s.context);
  return s;
}

test('every write method on every prototype is refused, and never reaches the original', () => {
  const s = guarded();
  for (const [owner, names] of Object.entries(WRITES)) {
    const target = { Collection: 'db.getCollection("c")', Database: 'db', Mongo: 'db.getMongo()' }[owner];
    for (const name of names) {
      assert.throws(() => s.run(`${target}.${name}({})`), new RegExp(`db-tools: refused: ${owner}\\.${name}\\(\\)`));
    }
  }
  assert.deepEqual(s.calls, []);
});

test('one level down, the service provider and the driver refuse every write method they have', () => {
  const s = guarded();
  const targets = {
    ServiceProvider: 'db.getMongo()._serviceProvider',
    DriverClient: 'db.getMongo()._serviceProvider.mongoClient',
    DriverDb: 'db.getMongo()._serviceProvider.mongoClient.db("x")',
    DriverCollection: 'db.getMongo()._serviceProvider.mongoClient.db("x").collection("y")',
  };
  for (const [owner, names] of Object.entries(DRIVER_WRITES)) {
    for (const name of names) {
      assert.throws(() => s.run(`${targets[owner]}.${name}("x")`), new RegExp(`db-tools: refused: ${owner}\\.${name}\\(\\)`));
    }
  }
  assert.deepEqual(s.calls, []);
});

test('the generic command runners stay, because the shell reads through them', () => {
  const s = guarded();
  s.run('db.getMongo()._serviceProvider.runCommandWithCheck("admin", { ping: 1 })');
  s.run('db.getMongo()._serviceProvider.mongoClient.db("x").command({ ping: 1 })');
  assert.deepEqual(s.calls, ['ServiceProvider.runCommandWithCheck', 'DriverDb.command']);
});

test('a shell without the internal layout still gets its shell-level guard', () => {
  const s = guarded({ noDriver: true });
  assert.throws(() => s.run('db.getCollection("c").deleteMany({})'), /refused/);
});

test('a computed name, an alias with call, and a second collection all end on the guarded prototype', () => {
  const s = guarded();
  assert.throws(() => s.run('db.getCollection("c")["delete" + "Many"]({})'), /refused/);
  assert.throws(() => s.run('const f = db.getCollection("c").drop; f.call(db.getCollection("d"))'), /refused/);
  assert.throws(() => s.run('db.getMongo().bulkWrite([])'), /refused/);
  assert.deepEqual(s.calls, []);
});

test('a guarded method cannot be replaced or redefined', () => {
  const s = guarded();
  s.run('Object.getPrototypeOf(db.getCollection("c")).deleteMany = function () { return "replaced"; }');
  assert.throws(() => s.run('db.getCollection("c").deleteMany({})'), /refused/);
  assert.throws(
    () => s.run('Object.defineProperty(Object.getPrototypeOf(db), "dropDatabase", { value: () => "x" })'),
    { name: 'TypeError' }, // the context's own TypeError, not this realm's
  );
});

test('a method a prototype does not have is skipped', () => {
  const s = guarded({ mongoLacks: ['getKeyVault'] });
  assert.equal(s.run('"getKeyVault" in db.getMongo()'), false);
});

test('aggregate refuses $out and $merge, in both call forms, on collections and on the database', () => {
  const s = guarded();
  for (const call of [
    'db.getCollection("c").aggregate([{ $match: {} }, { $out: "copy" }])',
    'db.getCollection("c").aggregate({ $match: {} }, { $merge: { into: "copy" } })',
    'db.aggregate([{ $currentOp: {} }, { $out: "ops" }])',
    'db.getCollection("c").aggregate([{ ["$o" + "ut"]: "copy" }])',
  ]) {
    assert.throws(() => s.run(call), /db-tools: refused: the \$(out|merge) stage writes/);
  }
  assert.deepEqual(s.calls, []);
});

test('aggregate passes a read pipeline on with a time limit, and the query can set its own', () => {
  const s = guarded();
  s.run('db.getCollection("c").aggregate([{ $match: { a: 1 } }])');
  s.run('db.getCollection("c").aggregate({ $match: {} }, { $count: "n" })');
  s.run('db.getCollection("c").aggregate([{ $count: "n" }], { maxTimeMS: 5, allowDiskUse: true })');
  assert.deepEqual(JSON.parse(JSON.stringify(s.calls)), [
    ['aggregate', [{ $match: { a: 1 } }], { maxTimeMS: 600000 }],
    ['aggregate', [{ $match: {} }, { $count: 'n' }], { maxTimeMS: 600000 }],
    ['aggregate', [{ $count: 'n' }], { maxTimeMS: 5, allowDiskUse: true }],
  ]);
});

test('find gets the limit, the time limit and the skip; a later .limit() of the query wins', () => {
  const s = guarded({}, { DBTOOLS_SKIP: '20' });
  assert.deepEqual({ ...s.run('db.getCollection("c").find({ a: 1 }).applied') }, { limit: 3, maxTimeMS: 600000, skip: 20 });
  assert.equal(s.run('db.getCollection("c").find({}).limit(1).applied.limit'), 1);
  assert.deepEqual(JSON.parse(JSON.stringify(s.calls[0])), ['find', [{ a: 1 }]]);
});

test('find without --skip applies none', () => {
  const s = guarded();
  assert.equal(s.run('db.getCollection("c").find({}).applied.skip'), undefined);
});

test('countDocuments gets a time limit', () => {
  const s = guarded();
  s.run('db.getCollection("c").countDocuments({ a: 1 })');
  s.run('db.getCollection("c").countDocuments()');
  assert.deepEqual(JSON.parse(JSON.stringify(s.calls)), [
    ['countDocuments', { a: 1 }, { maxTimeMS: 600000 }],
    ['countDocuments', {}, { maxTimeMS: 600000 }],
  ]);
});

test('the printer prints a cursor as one line per document, at most --limit, and says when it stopped', () => {
  const s = guarded({ docs: [{ a: 1 }, { a: 2 }, { a: 3 }, { a: 4 }] });
  s.run('__dbtoolsPrint(db.aggregate([]))');
  assert.deepEqual(s.printed, ['{"a":1}', '{"a":2}', '{"a":3}']);
  assert.deepEqual(s.reported, ['db-tools: 3 result(s); stopped at --limit 3, more exist\n']);
});

test('the printer says the limit was reached when a cursor ends exactly there', () => {
  const s = guarded({ docs: [{ a: 1 }, { a: 2 }, { a: 3 }] });
  s.run('__dbtoolsPrint(db.aggregate([]))');
  assert.deepEqual(s.reported, ['db-tools: 3 result(s); reached --limit 3, there may be more\n']);
});

test('the printer reports a short result plainly', () => {
  const s = guarded({ docs: [{ a: 1 }] });
  s.run('__dbtoolsPrint(db.aggregate([]))');
  assert.deepEqual(s.printed, ['{"a":1}']);
  assert.deepEqual(s.reported, ['db-tools: 1 result(s)\n']);
});

test('the printer prints arrays per element, scalars as one line, and undefined as nothing', () => {
  const s = guarded();
  s.run('__dbtoolsPrint(["a", "b", "c", "d"])');
  assert.deepEqual(s.printed, ['"a"', '"b"', '"c"']);
  assert.deepEqual(s.reported, ['db-tools: 3 result(s); stopped at --limit 3, more exist\n']);
  s.run('__dbtoolsPrint(42)');
  s.run('__dbtoolsPrint(undefined)');
  assert.deepEqual(s.printed.slice(3), ['42']);
});

test('the runtime list and the text check in lib/safety.sh name the same methods', () => {
  const bash = safetySource.match(/readonly MONGO_WRITE_METHODS='([^']+)'/)[1].split('|').sort();
  const runtime = [...new Set(Object.values(WRITES).flat())].sort();
  assert.deepEqual(runtime, bash);
});
