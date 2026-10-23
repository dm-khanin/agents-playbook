// mongo-guard.js — the second --eval of a db-tools mongosh query, run after mongo-connect.js and before the
// query itself: the runtime half of the read-only guard, the result limits and the printer.
//
// mongo-query.sh refuses an expression whose text names a write method or reaches for the process, the
// driver, a prototype or a computed member. What gets past it and calls a write method through the shell
// API (an alias, call or apply, a sibling database, a session, a second connection) still ends on the
// shell's own prototypes, so this script replaces those methods there with ones that throw, and pins them.
// It does the same one level down, on the service provider and the driver's Collection, Db and MongoClient,
// for their write methods; their generic command runners stay, because the shell's reads use them, so a
// generic command is stopped only by the text check. It also refuses aggregation pipelines with $out or
// $merge, gives find(), aggregate() and countDocuments() a time limit, gives find() the --limit and --skip,
// and defines __dbtoolsPrint, which prints a result as one EJSON line per document.
//
// None of this is a boundary: a database user with only the read role is.

// The write and administration methods by the prototype that carries them. Their union equals
// MONGO_WRITE_METHODS in lib/safety.sh; tests/test_mongo_guard.test.mjs checks it.
const DBTOOLS_WRITE_METHODS = {
  Collection: [
    'insert', 'insertOne', 'insertMany', 'update', 'updateOne', 'updateMany', 'replaceOne', 'remove',
    'deleteOne', 'deleteMany', 'bulkWrite', 'findAndModify', 'findOneAndUpdate', 'findOneAndReplace',
    'findOneAndDelete', 'drop', 'renameCollection', 'createIndex', 'createIndexes', 'ensureIndex',
    'dropIndex', 'dropIndexes', 'hideIndex', 'unhideIndex', 'reIndex', 'convertToCapped', 'mapReduce',
    'initializeOrderedBulkOp', 'initializeUnorderedBulkOp', 'createSearchIndex', 'createSearchIndexes',
    'updateSearchIndex', 'dropSearchIndex', 'compactStructuredEncryptionData', 'configureQueryAnalyzer',
    'getPlanCache', 'runCommand',
  ],
  Database: [
    'dropDatabase', 'createCollection', 'createView', 'runCommand', 'adminCommand', 'createUser',
    'updateUser', 'changeUserPassword', 'dropUser', 'dropAllUsers', 'grantRolesToUser',
    'revokeRolesFromUser', 'createRole', 'updateRole', 'dropRole', 'dropAllRoles', 'grantPrivilegesToRole',
    'revokePrivilegesFromRole', 'grantRolesToRole', 'revokeRolesFromRole', 'shutdownServer', 'fsyncLock',
    'fsyncUnlock', 'killOp', 'setProfilingLevel', 'setLogLevel', 'rotateCertificates',
  ],
  Mongo: ['bulkWrite', 'getClientEncryption', 'getKeyVault'],
};

// The same, one level down: what the shell calls to write. Missing objects or methods are skipped, so a
// mongosh with a different internal layout loses this layer, not the query.
const DBTOOLS_DRIVER_WRITE_METHODS = {
  ServiceProvider: [
    'bulkWrite', 'clientBulkWrite', 'createIndexes', 'createSearchIndexes', 'deleteMany', 'deleteOne',
    'dropCollection', 'dropDatabase', 'dropSearchIndex', 'findOneAndDelete', 'findOneAndReplace',
    'findOneAndUpdate', 'initializeBulkOp', 'insertMany', 'insertOne', 'renameCollection', 'replaceOne',
    'updateMany', 'updateOne', 'updateSearchIndex',
  ],
  DriverCollection: [
    'insertOne', 'insertMany', 'bulkWrite', 'updateOne', 'updateMany', 'replaceOne', 'deleteOne', 'deleteMany',
    'rename', 'drop', 'createIndex', 'createIndexes', 'dropIndex', 'dropIndexes', 'findOneAndDelete',
    'findOneAndReplace', 'findOneAndUpdate', 'initializeOrderedBulkOp', 'initializeUnorderedBulkOp',
    'createSearchIndex', 'createSearchIndexes', 'dropSearchIndex', 'updateSearchIndex',
  ],
  DriverDb: ['dropCollection', 'dropDatabase', 'createCollection', 'renameCollection', 'createIndex'],
  DriverClient: ['bulkWrite'],
};

(() => {
  const limit = Number(process.env.DBTOOLS_LIMIT);
  const skip = Number(process.env.DBTOOLS_SKIP || 0);
  const maxTimeMS = Number(process.env.DBTOOLS_MAX_TIME_MS);
  const writeStages = ['$out', '$merge'];

  const pin = (prototype, name, value) =>
    Object.defineProperty(prototype, name, { value, writable: false, configurable: false, enumerable: false });

  const refusing = (owner, name) =>
    function refused() {
      throw new Error(`db-tools: refused: ${owner}.${name}() can write, and this connection is for reading`);
    };

  const prototypes = {
    Collection: Object.getPrototypeOf(db.getCollection('db_tools')),
    Database: Object.getPrototypeOf(db),
    Mongo: Object.getPrototypeOf(db.getMongo()),
  };

  const serviceProvider = db.getMongo()._serviceProvider;
  const client = serviceProvider && serviceProvider.mongoClient;
  const driverDb = client && typeof client.db === 'function' ? client.db('db_tools') : undefined;
  const driverCollection = driverDb && typeof driverDb.collection === 'function' ? driverDb.collection('db_tools') : undefined;
  Object.assign(prototypes, {
    ServiceProvider: serviceProvider && Object.getPrototypeOf(serviceProvider),
    DriverCollection: driverCollection && Object.getPrototypeOf(driverCollection),
    DriverDb: driverDb && Object.getPrototypeOf(driverDb),
    DriverClient: client && Object.getPrototypeOf(client),
  });

  for (const [owner, names] of [...Object.entries(DBTOOLS_WRITE_METHODS), ...Object.entries(DBTOOLS_DRIVER_WRITE_METHODS)]) {
    for (const name of names) {
      if (prototypes[owner] && name in prototypes[owner]) pin(prototypes[owner], name, refusing(owner, name));
    }
  }

  // aggregate(pipeline, options) or aggregate(stage, stage, ...); $out and $merge can only be top-level stages.
  for (const owner of ['Collection', 'Database']) {
    const aggregate = prototypes[owner].aggregate;
    pin(prototypes[owner], 'aggregate', function (...args) {
      const [pipeline, options] = Array.isArray(args[0]) ? [args[0], args[1] || {}] : [args, {}];
      for (const stage of pipeline) {
        const key = stage && typeof stage === 'object' ? Object.keys(stage).find((k) => writeStages.includes(k)) : undefined;
        if (key) throw new Error(`db-tools: refused: the ${key} stage writes`);
      }
      return aggregate.call(this, pipeline, { maxTimeMS, ...options });
    });
  }

  // A .limit() or .maxTimeMS() that the query sets itself comes later and wins.
  const find = prototypes.Collection.find;
  pin(prototypes.Collection, 'find', function (...args) {
    const cursor = find.apply(this, args).limit(limit).maxTimeMS(maxTimeMS);
    return skip ? cursor.skip(skip) : cursor;
  });

  const countDocuments = prototypes.Collection.countDocuments;
  pin(prototypes.Collection, 'countDocuments', function (filter = {}, options = {}) {
    return countDocuments.call(this, filter, { maxTimeMS, ...options });
  });

  const line = (value) => print(EJSON.stringify(value, { relaxed: true }));
  // A find() cursor ends at --limit on the server, so reaching it only says that more may exist.
  const report = (count, more) => {
    const cut = more ? `; stopped at --limit ${limit}, more exist` : count === limit ? `; reached --limit ${limit}, there may be more` : '';
    console.error(`db-tools: ${count} result(s)${cut}`);
  };
  const isCursor = (value) =>
    value !== null && typeof value === 'object' && typeof value.hasNext === 'function' && typeof value.next === 'function';

  // A cursor or an array prints one line per element, at most --limit of them; anything else prints as
  // one line, and undefined (print() returns it) prints nothing.
  globalThis.__dbtoolsPrint = function (value) {
    if (value === undefined) return;
    if (isCursor(value)) {
      let count = 0;
      while (count < limit && value.hasNext()) {
        line(value.next());
        count += 1;
      }
      report(count, value.hasNext());
    } else if (Array.isArray(value)) {
      value.slice(0, limit).forEach((element) => line(element));
      report(Math.min(value.length, limit), value.length > limit);
    } else {
      line(value);
    }
  };
})();
