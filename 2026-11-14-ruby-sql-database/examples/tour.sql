-- A tour of Garnet. Run with:  bin/garnet tour.db < examples/tour.sql
CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT NOT NULL, country TEXT);
CREATE TABLE books (
  id INTEGER PRIMARY KEY,
  title TEXT NOT NULL,
  author_id INTEGER,
  year INTEGER,
  pages INTEGER,
  rating REAL
);
CREATE INDEX books_author ON books(author_id);
CREATE INDEX books_year ON books(year);

INSERT INTO authors (name, country) VALUES
  ('Ursula K. Le Guin', 'US'), ('Stanislaw Lem', 'PL'), ('Octavia Butler', 'US'),
  ('Italo Calvino', 'IT'), ('Liu Cixin', 'CN'), ('Nobody Yet', NULL);

INSERT INTO books (title, author_id, year, pages, rating) VALUES
  ('The Left Hand of Darkness', 1, 1969, 304, 4.3),
  ('The Dispossessed', 1, 1974, 387, 4.4),
  ('A Wizard of Earthsea', 1, 1968, 183, 4.1),
  ('Solaris', 2, 1961, 204, 4.0),
  ('The Cyberiad', 2, 1965, 295, 4.2),
  ('Kindred', 3, 1979, 264, 4.5),
  ('Parable of the Sower', 3, 1993, 345, 4.4),
  ('Invisible Cities', 4, 1972, 165, 4.3),
  ('If on a winter''s night a traveler', 4, 1979, 260, 4.1),
  ('The Three-Body Problem', 5, 2008, 400, 4.1),
  ('The Dark Forest', 5, 2008, 512, 4.4);

-- joins, grouping, aggregates, LEFT JOIN null-extension
SELECT a.name, count(b.id) AS books, round(avg(b.rating), 2) AS avg_rating, min(b.year) AS first
FROM authors a LEFT JOIN books b ON b.author_id = a.id
GROUP BY a.name
ORDER BY books DESC, a.name;

-- correlated subquery: each author's best book
SELECT a.name, b.title, b.rating
FROM authors a JOIN books b ON b.author_id = a.id
WHERE b.rating = (SELECT max(rating) FROM books WHERE author_id = a.id)
ORDER BY b.rating DESC, a.name;

-- the planner picks index range scans and index nested-loop joins
EXPLAIN SELECT b.title, a.name FROM books b JOIN authors a ON a.id = b.author_id
WHERE b.year BETWEEN 1970 AND 1980;

SELECT b.title, a.name FROM books b JOIN authors a ON a.id = b.author_id
WHERE b.year BETWEEN 1970 AND 1980 ORDER BY b.year;

-- CASE, string functions, LIKE, IN, compound queries
SELECT title, CASE WHEN pages > 350 THEN 'long' WHEN pages > 200 THEN 'medium' ELSE 'short' END AS size
FROM books WHERE title LIKE 'the %' AND author_id IN (1, 2, 5) ORDER BY pages;

SELECT country FROM authors WHERE country IS NOT NULL
UNION SELECT 'XX' ORDER BY 1;

-- transactions: changes are invisible to the file until COMMIT, and ROLLBACK undoes them
BEGIN;
DELETE FROM books WHERE year < 1970;
SELECT count(*) AS during_txn FROM books;
ROLLBACK;
SELECT count(*) AS after_rollback FROM books;

-- constraint errors abort just the failing statement
INSERT INTO books (id, title) VALUES (1, 'duplicate primary key');
INSERT INTO authors (name) VALUES (NULL);
