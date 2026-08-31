CREATE TABLE ZAEANNOTATION(
  Z_PK INTEGER PRIMARY KEY,
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
  ZFUTUREPROOFING5 TEXT
);

INSERT INTO ZAEANNOTATION VALUES
  (101,'uuid-green','asset-1',0,0,1,1,101,201,'needle-selected','representative green','', 'epubcfi(/6/8[ch1]!/4/2,:1,:2)',NULL),
  (102,'uuid-blue','asset-1',0,0,2,1,102,202,'blue quote','representative blue','needle-note', 'epubcfi(/6/8[ch1]!/4/2,:2,:3)',NULL),
  (103,'uuid-yellow','asset-2',0,0,3,2,103,203,'yellow quote','representative yellow','yellow note',NULL,NULL),
  (104,'uuid-pink','asset-2',0,1,4,1,104,204,'pink quote','representative pink','pink note',NULL,NULL),
  (105,'uuid-purple','asset-3',0,0,5,2,105,205,'purple quote','representative purple','purple note',NULL,NULL),
  (199,'uuid-position','asset-1',0,0,0,3,199,299,'','','','epubcfi(/6/8[current]!/4/2,:0,:0)',NULL);
