CREATE TABLE votes (
	id SERIAL NOT NULL PRIMARY KEY ,
	electionID integer NOT NULL,
	machineID integer NOT NULL,
	voting integer NOT NULL
);