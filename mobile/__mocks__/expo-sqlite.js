const rows = [];
const db = {
  execAsync: jest.fn(),
  getAllAsync: jest.fn(() => Promise.resolve([...rows])),
  runAsync: jest.fn(() => Promise.resolve({ changes: 1 })),
};

module.exports = {
  openDatabaseAsync: jest.fn(() => Promise.resolve(db)),
  __mockDb: db,
  __mockRows: rows,
};
