CREATE EXTENSION hstore;

CREATE OR REPLACE FUNCTION HAinit(tb text, VARIADIC nBin int[]) RETURNS void
AS $$
DECLARE
    cnt int;    -- count through records selected
    i int;      -- counter
    j int;      -- counter
    nRec int;   -- record how many records returned

    recCol record;  -- for looping through selects
    recRec record;  -- for looping through tuples
    nDiv int;   -- for updating bins
    nMod int;   -- for updating bins
BEGIN
--  add the ha_id column to the original table
    EXECUTE format('ALTER TABLE %s ADD COLUMN ha_id SERIAL', tb);

--  create a table to store number of bins on each column
    EXECUTE format('CREATE TABLE %s(dimension varchar(255), nbin int, nobj int);', tb || '_HATMP');

    cnt := 0;
    FOR recCol IN EXECUTE format('SELECT column_name, data_type FROM information_schema.columns WHERE table_name = %s', quote_nullable(tb))
    LOOP
        IF recCol.column_name = 'ha_id' THEN CONTINUE; END IF;
        cnt := cnt + 1;
        -- update the _HATMP table;
        EXECUTE format('INSERT INTO %s_hatmp VALUES(%s, %s, (SELECT COUNT(*) FROM %s WHERE %s IS NOT NULL));', tb, quote_nullable(recCol.column_name), nBin[cnt]::text, tb, recCol.column_name);

        -- create bins
        i := 1;
        LOOP
            EXIT WHEN i > nBin[cnt];
            EXECUTE format('CREATE table habin_%s_%s_%s(val %s, ha_id int);', tb, recCol.column_name, i::text, recCol.data_type);
            EXECUTE format('CREATE INDEX ha_%s_%s_%s ON habin_%s_%s_%s USING BTREE (val);', tb, recCol.column_name, i::text, tb, recCol.column_name, i::text);
            i := i + 1;
        END LOOP;

        -- update bins
        EXECUTE format('SELECT COUNT(*) FROM %s WHERE %s IS NOT NULL;', tb, recCol.column_name) INTO nRec;
        nDiv = nRec / nBin[cnt];
        nMod = nRec % nBin[cnt];
        i := 1;
        j := 0;
        FOR recRec IN EXECUTE format('SELECT %s AS val, ha_id FROM %s WHERE %s IS NOT NULL ORDER BY %s', recCol.column_name, tb, recCol.column_name, recCol.column_name)
        LOOP
            j := j + 1;
            EXECUTE format('INSERT INTO habin_%s_%s_%s VALUES(%s, %s);', tb, recCol.column_name, i::text, recRec.val, recRec.ha_id);
            IF j <= (nDiv + 1) * nMod THEN
                IF j % (nDiv + 1) = 0 THEN
                    i := i + 1;
                END IF;
            ELSE
                IF (j - (nDiv + 1) * nMod) % nDiv = 0 THEN
                    i := i + 1;
                END IF;
            END IF;
        END LOOP;
    END LOOP;

    EXECUTE format('
    CREATE OR REPLACE FUNCTION HA_%s_triIns() RETURNS TRIGGER 
    AS $T2$
    DECLARE
        par record;
        recl record;
        recr record;
        nbin int;
        nobj int;
        ist int;
    BEGIN
        FOR par IN SELECT (each(hstore(NEW))).*
        LOOP
            IF par.key = ''ha_id'' THEN CONTINUE; END IF;
            IF par.value IS NOT NULL THEN
                EXECUTE format(''SELECT nbin FROM %s_hatmp WHERE dimension = %%s'', quote_nullable(par.key)) INTO nbin;
                EXECUTE format(''SELECT nobj FROM %s_hatmp WHERE dimension = %%s'', quote_nullable(par.key)) INTO nobj;
                ist = nobj %% nbin + 1;
    
                IF ist < nbin AND nobj > nbin THEN  
                    -- get the smallest of the right bin
                    EXECUTE format(''SELECT * FROM habin_%s_%%s_%%s ORDER BY val LIMIT 1'', par.key, (ist+1)::text) INTO recr;
                    LOOP
                        EXIT WHEN par.value::float <= recr.val::float OR recr IS NULL;
                        EXECUTE format(''INSERT INTO habin_%s_%%s_%%s VALUES(%%s, %%s)'', par.key, ist::text, recr.val, recr.ha_id);
                        EXECUTE format(''DELETE FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, (ist+1)::text, recr.ha_id);
                        ist := ist + 1;
                        IF ist = nbin THEN EXIT; END IF;
                        EXECUTE format(''SELECT * FROM habin_%s_%%s_%%s ORDER BY val LIMIT 1'', par.key, (ist+1)::text) INTO recr;
                    END LOOP;
                END IF;
                IF ist > 1 THEN
                    -- get the largest of the left bin
                    EXECUTE format(''SELECT * FROM habin_%s_%%s_%%s ORDER BY val DESC LIMIT 1'', par.key, (ist-1)::text) INTO recl;
                    LOOP
                        EXIT WHEN par.value::float >= recl.val::float;
                        EXECUTE format(''INSERT INTO habin_%s_%%s_%%s VALUES(%%s, %%s)'', par.key, ist::text, recl.val, recl.ha_id);
                        EXECUTE format(''DELETE FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, (ist-1)::text, recl.ha_id);
                        ist := ist - 1;
                        IF ist = 1 THEN EXIT; END IF;
                        EXECUTE format(''SELECT * FROM habin_%s_%%s_%%s ORDER BY val DESC LIMIT 1'', par.key, (ist-1)::text) INTO recl;
                    END LOOP;
                END IF;
                EXECUTE format(''INSERT INTO habin_%s_%%s_%%s VALUES(%%s, %%s)'', par.key, ist::text, par.value, NEW.ha_id);
                EXECUTE format(''UPDATE %s_hatmp SET nobj = nobj + 1 where dimension = %%s'', quote_nullable(par.key));
            END IF;
        END LOOP;
        RETURN NEW;
    END
    $T2$ LANGUAGE plpgsql;', tb, tb, tb, tb, tb, tb, tb, tb, tb, tb, tb, tb, tb);

    EXECUTE format('
    CREATE TRIGGER %s_HAins AFTER INSERT ON %s
    FOR EACH ROW EXECUTE PROCEDURE HA_%s_triins();', tb, tb, tb); 

    EXECUTE format('
    CREATE OR REPLACE FUNCTION HA_%s_tridel() RETURNS TRIGGER 
    AS $T2$
    DECLARE
        par record;
        rec record;
        nbin int;
        nobj int;
        exst int;
        del int;
    BEGIN
        FOR par IN SELECT (each(hstore(OLD))).*
        LOOP
            IF par.key = ''ha_id'' THEN CONTINUE; END IF;
            IF par.value IS NOT NULL THEN
                EXECUTE format(''SELECT nbin FROM %s_hatmp WHERE dimension = %%s'', quote_nullable(par.key)) INTO nbin;
                EXECUTE format(''SELECT nobj FROM %s_hatmp WHERE dimension = %%s'', quote_nullable(par.key)) INTO nobj;

                del := 1;
                LOOP
                    EXIT WHEN del >= nbin OR (nobj < nbin AND del > nobj);
                    EXECUTE format(''SELECT count(*) FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, del::text, OLD.ha_id::text) INTO exst;
                    IF exst > 0 THEN EXIT; END IF;
                    del := del + 1;
                END LOOP;
                EXECUTE format(''DELETE FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, del::text, OLD.ha_id::text);
                EXECUTE format(''UPDATE %s_hatmp SET nobj = nobj - 1 WHERE dimension = %%s'', quote_nullable(par.key));
    
                IF del < (nobj - 1) %% nbin + 1 THEN
                    LOOP
                        EXIT WHEN del = (nobj - 1) %% nbin + 1;
                        EXECUTE format(''SELECT * FROM habin_%s_%%s_%%s ORDER BY val LIMIT 1'', par.key, (del+1)::text) INTO rec;
                        EXECUTE format(''INSERT INTO habin_%s_%%s_%%s VALUES(%%s, %%s)'', par.key, del::text, rec.val::text, rec.ha_id::text);
                        EXECUTE format(''DELETE FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, (del+1)::text, rec.ha_id::text);
                        del := del + 1;
                    END LOOP;
                ELSEIF del > (nobj - 1) %% nbin + 1 THEN
                    LOOP
                        EXIT WHEN del = (nobj - 1) %% nbin + 1;
                        EXECUTE format(''SELECT * FROM habin_%s_%%s_%%s ORDER BY val DESC LIMIT 1'', par.key, (del-1)::text) INTO rec;
                        EXECUTE format(''INSERT INTO habin_%s_%%s_%%s VALUES(%%s, %%s)'', par.key, del::text, rec.val::text, rec.ha_id::text);
                        EXECUTE format(''DELETE FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, (del-1)::text, rec.ha_id::text);
                        del := del - 1;
                    END LOOP;
                END IF;
            END IF;
        END LOOP;
        RETURN OLD;
    END
    $T2$ LANGUAGE plpgsql;', tb, tb, tb, tb, tb, tb, tb, tb, tb, tb, tb, tb);

    EXECUTE format('
    CREATE TRIGGER %s_hadel AFTER DELETE ON %s
    FOR EACH ROW EXECUTE PROCEDURE HA_%s_tridel();', tb, tb, tb);

    EXECUTE format('
    CREATE OR REPLACE FUNCTION HA_%s_triupd() RETURNS TRIGGER 
    AS $T2$
    DECLARE
        par record;
        rec record;
        nbin int;
        nobj int;
        exst int;
        upd int;
    BEGIN
        FOR par IN SELECT (each(hstore(NEW))).*
        LOOP
            IF par.key = ''ha_id'' THEN CONTINUE; END IF;
            IF par.value IS NOT NULL THEN
                EXECUTE format(''SELECT nbin FROM %s_hatmp WHERE dimension = %%s'', quote_nullable(par.key)) INTO nbin;
                EXECUTE format(''SELECT nobj FROM %s_hatmp WHERE dimension = %%s'', quote_nullable(par.key)) INTO nobj;

                upd := 1;
                LOOP
                    EXIT WHEN upd >= nbin OR (nobj < nbin AND upd > nobj);
                    EXECUTE format(''SELECT count(*) FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, upd::text, NEW.ha_id::text) INTO exst;
                    IF exst > 0 THEN EXIT; END IF;
                    upd := upd + 1;
                END LOOP;
                EXECUTE format(''DELETE FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, upd::text, NEW.ha_id::text);
    
                IF upd < nbin THEN  
                    LOOP
                        EXIT WHEN upd = nbin;
                        EXECUTE format(''SELECT * FROM habin_%s_%%s_%%s ORDER BY val LIMIT 1'', par.key, (upd+1)::text) INTO rec;
                        EXIT WHEN rec IS NULL OR par.value::float <= rec.val::float;
                        EXECUTE format(''INSERT INTO habin_%s_%%s_%%s VALUES(%%s, %%s)'', par.key, upd::text, rec.val, rec.ha_id);
                        EXECUTE format(''DELETE FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, (upd+1)::text, rec.ha_id);
                        upd := upd + 1;
                    END LOOP;
                END IF;
                IF upd > 1 THEN
                    LOOP
                        EXIT WHEN upd = 1;
                        EXECUTE format(''SELECT * FROM habin_%s_%%s_%%s ORDER BY val DESC LIMIT 1'', par.key, (upd-1)::text) INTO rec;
                        EXIT WHEN par.value::float >= rec.val::float;
                        EXECUTE format(''INSERT INTO habin_%s_%%s_%%s VALUES(%%s, %%s)'', par.key, upd::text, rec.val, rec.ha_id);
                        EXECUTE format(''DELETE FROM habin_%s_%%s_%%s WHERE ha_id = %%s'', par.key, (upd-1)::text, rec.ha_id);
                        upd := upd - 1;
                    END LOOP;
                END IF;

                EXECUTE format(''INSERT INTO habin_%s_%%s_%%s VALUES(%%s, %%s)'', par.key, upd::text, par.value::text, NEW.ha_id::text);
            END IF;
        END LOOP;
        RETURN NEW;
    END
    $T2$ LANGUAGE plpgsql;', tb, tb, tb, tb, tb, tb, tb, tb, tb, tb, tb, tb);

    EXECUTE format('
    CREATE TRIGGER %s_haupd BEFORE UPDATE ON %s
    FOR EACH ROW EXECUTE PROCEDURE HA_%s_triupd();', tb, tb, tb);
END
$$
language plpgsql;
