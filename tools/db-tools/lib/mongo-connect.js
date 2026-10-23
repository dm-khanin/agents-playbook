// mongo-connect.js — the first --eval of every db-tools mongosh call. The connection string arrives in the
// environment, never on the command line, and leaves the environment as soon as the connection exists.
db = connect(process.env.DBTOOLS_MONGO_URI);
delete process.env.DBTOOLS_MONGO_URI;
