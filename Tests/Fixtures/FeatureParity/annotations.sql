CREATE TABLE Z_PRIMARYKEY(Z_NAME TEXT,Z_ENT INTEGER,Z_MAX INTEGER);
CREATE TABLE ZAEANNOTATION(
  Z_PK INTEGER PRIMARY KEY,
  Z_ENT INTEGER,
  Z_OPT INTEGER,
  ZANNOTATIONUUID TEXT,
  ZANNOTATIONASSETID TEXT,
  ZANNOTATIONDELETED INTEGER,
  ZANNOTATIONISUNDERLINE INTEGER,
  ZANNOTATIONSTYLE INTEGER,
  ZANNOTATIONTYPE INTEGER,
  ZANNOTATIONCREATIONDATE REAL,
  ZANNOTATIONMODIFICATIONDATE REAL,
  ZANNOTATIONSELECTEDTEXT TEXT,
  ZANNOTATIONREPRESENTATIVETEXT TEXT,
  ZANNOTATIONNOTE TEXT,
  ZANNOTATIONLOCATION TEXT,
  ZPLABSOLUTEPHYSICALLOCATION INTEGER,
  ZPLLOCATIONRANGESTART INTEGER,
  ZPLLOCATIONRANGEEND INTEGER,
  ZFUTUREPROOFING5 TEXT,
  ZFUTUREPROOFING6 TEXT
);

INSERT INTO Z_PRIMARYKEY VALUES ('AEAnnotation',11,200);

INSERT INTO ZAEANNOTATION VALUES
  (12,11,1,'uuid-local-12','asset-2',0,0,5,1,5,50,'local twelve','rep twelve','note twelve',NULL,NULL,NULL,NULL,NULL,NULL),
  (101,11,1,'uuid-a','asset-1',0,0,1,1,10,100,'quote alpha','rep alpha','note alpha',NULL,NULL,NULL,NULL,NULL,NULL),
  (102,11,1,'uuid-system','asset-1',0,0,1,3,11,110,'system bookmark text','system rep','system note',NULL,NULL,NULL,NULL,NULL,NULL),
  (103,11,1,'uuid-deleted','asset-1',1,0,1,1,12,120,'deleted text','deleted rep','deleted note',NULL,NULL,NULL,NULL,NULL,NULL),
  (104,11,1,'uuid-unknown-delete','asset-1',NULL,0,1,1,13,130,'unknown deleted text','unknown rep','unknown note',NULL,NULL,NULL,NULL,NULL,NULL),
  (105,11,1,'uuid-orphan','orphan-asset',0,0,2,1,14,140,'orphan quote','orphan rep','orphan note',NULL,NULL,NULL,NULL,NULL,NULL),
  (106,11,1,'12abc','asset-2',0,0,3,1,15,150,'stable string annotation','stable rep','stable note',NULL,NULL,NULL,NULL,NULL,NULL),
  (107,11,4,'uuid-update','asset-1',0,0,4,1,16,160,'update quote','update rep','old note',NULL,NULL,NULL,NULL,NULL,NULL),
  (108,11,2,'uuid-delete','asset-2',0,0,1,1,17,170,'delete quote','delete rep','delete note',NULL,NULL,NULL,NULL,NULL,NULL),
  (109,11,1,'dup','asset-2',0,0,1,1,18,180,'dup one','dup rep one','dup note one',NULL,NULL,NULL,NULL,NULL,NULL),
  (110,11,1,'dup','asset-3',0,0,1,1,19,190,'dup two','dup rep two','dup note two',NULL,NULL,NULL,NULL,NULL,NULL),
  (111,11,1,'uuid-raw-unknown','asset-3',0,0,2,NULL,20,200,'raw unknown type','raw rep','raw note',NULL,NULL,NULL,NULL,NULL,NULL);
