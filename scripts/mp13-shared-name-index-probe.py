"""Disposable research for the selected byte-ordered name layout; append acceptance remains separate.

Called by mp13-browse-sql-prototype.py's bounded owned-cluster lifecycle.
Existing unique-name and category indexes/column collations remain unchanged.
"""

import json


def probe(sql, database, evidence, save, fixture_typeid):
    def literal(value):
        return "'" + value.replace("'", "''") + "'"

    def successor(value):
        for i in range(len(value) - 1, -1, -1):
            n = ord(value[i])
            if n < 0x10FFFF:
                n += 1
                if 0xD800 <= n <= 0xDFFF:
                    n = 0xE000
                return value[:i] + chr(n)
        return None

    def nodes(plan):
        yield plan
        for child in plan.get('Plans', []):
            yield from nodes(child)

    sql('CREATE INDEX IF NOT EXISTS ix_streams_browse_name ON kiroku.streams '
        '(stream_name COLLATE "C") WHERE stream_id <> 0;', database)
    for size in [1000, 20000]:
        catalog = [category + '-' + fixture_typeid(n)
                   for category in ['orders', 'noise'] for n in range(1, size + 1)]
        seed = ('INSERT INTO kiroku.streams(stream_name) SELECT value FROM unnest(ARRAY['
                + ','.join(map(literal, catalog))
                + ']) input(value) ON CONFLICT DO NOTHING; ')
        names = ['', '-x', 'orders', 'orders-', 'orders-%literal', 'orders-_literal',
                 'orders-éclair', 'orders-漢字', '$all-x', 'pm', 'pm-a',
                 'pm:billing-a', 'pm:fulfillment-a', 'pma-a', 'orderbook-x',
                 'orders.bar-a', 'é-x', 'e\u0301-x', '\U0010ffff', '\U0010ffff-x']
        seed += ('INSERT INTO kiroku.streams(stream_name) VALUES '
                 + ','.join('(' + literal(n) + ')' for n in names)
                 + ' ON CONFLICT DO NOTHING; ANALYZE kiroku.streams;')
        sql(seed, database)
        evidence.setdefault('fixtures', []).append({'database': database, 'size': size, 'fixture': 'deterministic UUIDv7 TypeIDs', 'sql': seed})
        evidence.setdefault('layouts', []).append({'database': database, 'size': size,
            'layout': 'existing_indexes_plus_one_byte_name_index',
            'indexes': json.loads(sql("SELECT json_agg(json_build_object('name',indexname,"
                "'definition',indexdef,'bytes',pg_relation_size((schemaname||'.'||indexname)::regclass)) "
                "ORDER BY indexname) FROM pg_indexes WHERE schemaname='kiroku' AND tablename='streams';", database))})
        cases = [(None, None, None), (None, 'orders-', None),
                 (None, 'absent-', None), (None, '%', None),
                 (None, 'orders-%', None), (None, 'orders-_', None),
                 (None, 'é', None), (None, 'e\u0301', None),
                 (None, '\U0010ffff', None), (None, '', 'orders-000995'),
                 (None, 'orders-' + fixture_typeid(995)[:-1], 'orders-' + fixture_typeid(995)),
                 (None, 'orders-', 'orders-999999'),
                 ('orders', None, None), ('orders', None, 'orders-' + fixture_typeid(size - 10)),
                 ('orders', 'orders-' + fixture_typeid(995)[:-1], 'orders-' + fixture_typeid(995)),
                 ('orders', 'absent', None), ('orders', 'orders', None),
                 ('missing', None, None), ('', None, None),
                 ('$all', None, None), ('pm', None, None), ('orders-extra', None, None)]
        for category, prefix, cursor in cases:
            # Category = bare name OR category + '-' descendants. Intersect
            # each disjoint interval with the literal-prefix interval before SQL.
            ranges = [(None, None)] if category is None else [
                (category, category, 'equal'), (category + '-', successor(category + '-'))]
            if category is not None and '-' in category:
                ranges = []
            parts, parameters = [], []
            for interval in ranges:
                equal = len(interval) == 3
                lower, upper = interval[:2]
                if equal:
                    if prefix is not None and not lower.startswith(prefix):
                        continue
                    if cursor is not None and lower <= cursor:
                        continue
                else:
                    if prefix is not None:
                        lower = max(lower or '', prefix)
                        end = successor(prefix)
                        upper = min(x for x in [upper, end] if x is not None) if upper is not None or end is not None else None
                    if upper is not None and lower is not None and lower >= upper:
                        continue
                predicates = ['stream_id <> 0']
                for operator, value in [('=' if equal else '>=', lower), ('>', cursor)]:
                    if value is not None:
                        parameters.append(value)
                        predicates.append(f'stream_name COLLATE "C" {operator} ${len(parameters)}')
                inner = ('SELECT stream_id, stream_name COLLATE "C" AS stream_name, stream_version, created_at, deleted_at, truncate_before FROM streams WHERE '
                         + ' AND '.join(predicates) + ' ORDER BY stream_name LIMIT 11')
                if not equal and upper is not None:
                    parameters.append(upper)
                    inner = 'SELECT * FROM (' + inner + ') bounded WHERE stream_name COLLATE "C" < $' + str(len(parameters))
                parts.append('(' + inner + ')')
            query = ('SELECT * FROM (' + ' UNION ALL '.join(parts)
                     + ') matching ORDER BY stream_name LIMIT 11') if parts else 'SELECT stream_id,stream_name,stream_version,created_at,deleted_at,truncate_before FROM streams WHERE false'
            for mode in ['force_generic_plan', 'force_custom_plan']:
                types = ','.join(['text'] * len(parameters))
                prepare = f'PREPARE probe({types}) AS {query};' if types else f'PREPARE probe AS {query};'
                execute = 'EXECUTE probe(' + ','.join(map(literal, parameters)) + ');' if parameters else 'EXECUTE probe;'
                settings = f'SET search_path=kiroku,pg_catalog; SET plan_cache_mode={mode}; SET statement_timeout=\'10s\'; '
                transcript = settings + prepare
                plan = json.loads(sql(transcript + 'EXPLAIN (ANALYZE,BUFFERS,COSTS OFF,TIMING OFF,FORMAT JSON) ' + execute, database))
                actual = [row.split('|')[1] for row in sql(transcript + execute, database).splitlines()]
                reference = 'SELECT stream_name FROM kiroku.streams WHERE stream_id <> 0'
                if category is not None:
                    reference += ' AND category COLLATE "C" = ' + literal(category)
                if prefix is not None:
                    reference += ' AND starts_with(stream_name,' + literal(prefix) + ')'
                if cursor is not None:
                    reference += ' AND stream_name COLLATE "C" > ' + literal(cursor)
                expected = sql(reference + ' ORDER BY stream_name COLLATE "C" LIMIT 11;', database).splitlines()
                top = plan[0]['Plan']
                examined = sum((n.get('Actual Rows', 0) + n.get('Rows Removed by Filter', 0)) * n.get('Actual Loops', 1)
                               for n in nodes(top) if n.get('Relation Name') == 'streams')
                buffers = top.get('Shared Hit Blocks', 0) + top.get('Shared Read Blocks', 0)
                evidence['cases'].append({'database': database, 'size': size, 'mode': mode,
                    'category': category, 'prefix': prefix, 'cursor': cursor, 'sql': transcript + execute,
                    'plan': plan, 'items': actual, 'expected_items': expected,
                    'correct_results': actual == expected, 'rows_examined': examined, 'buffers': buffers,
                    'within_budget': actual == expected and examined <= 64 and buffers <= 64})
                save()
    namespace_windows(sql, database, evidence, save)


def namespace_windows(sql, database, evidence, save):
    """Prove bounded scanning and empty-match progress, not worker acceptance."""
    def nodes(plan):
        yield plan
        for child in plan.get('Plans', []):
            yield from nodes(child)

    query = """
    WITH scanned AS MATERIALIZED (
      SELECT stream_version, category, original_stream_id FROM stream_events
      WHERE stream_id=0 AND stream_version>$1
      ORDER BY stream_version LIMIT 32
    )
    SELECT json_build_object(
      'scanned',count(*),'last_scanned',max(stream_version),
      'matches',coalesce(json_agg(stream_version ORDER BY stream_version)
        FILTER (WHERE (category COLLATE "C"=$3 OR starts_with(category,$3||':'))
          AND (((hashtextextended(original_stream_id::text,0)%$5)+$5)%$5)=$4),'[]'::json))
    FROM scanned WHERE stream_version<=$2
    """
    for size in [1000, 20000]:
        # Sparse global positions model compaction gaps. These are direct SQL
        # fixtures, not append/delivery benchmarks. No streams join is needed:
        # migration 0012 already denormalizes category onto global entries.
        seed = f"""
        INSERT INTO kiroku.events(event_id,event_type,data)
          SELECT md5(n::text)::uuid,'probe','{{}}'::jsonb
          FROM generate_series(1,{size}) n WHERE n%17<>0 ON CONFLICT DO NOTHING;
        INSERT INTO kiroku.stream_events(event_id,stream_id,stream_version,
          original_stream_id,original_stream_version,category)
          SELECT md5(n::text)::uuid,0,n,s.stream_id,n,s.category
          FROM generate_series(1,{size}) n JOIN kiroku.streams s ON
            s.stream_name=CASE WHEN n%97=0 THEN 'pm:billing-a' ELSE 'orders' END
          WHERE n%17<>0 ON CONFLICT DO NOTHING;
        ANALYZE kiroku.stream_events;
        """
        sql(seed, database)
        evidence.setdefault('fixtures', []).append({'database': database, 'event_positions': size, 'sql': seed})
        for mode in ['force_generic_plan', 'force_custom_plan']:
            for cursor, namespace, member, members in [
                (0, 'pm', 0, 1), (size-40, 'pm', 0, 1),
                (size-40, 'absent', 0, 1), (size, 'pm', 0, 1),
                (size-40, 'pm:billing', 0, 1), (0, 'pm', 0, 2)]:
                settings = f'SET search_path=kiroku,pg_catalog; SET plan_cache_mode={mode}; SET statement_timeout=\'10s\'; '
                prepare = settings + 'PREPARE probe(bigint,bigint,text,bigint,bigint) AS ' + query + '; '
                execute = f"EXECUTE probe({cursor},{size},'{namespace}',{member},{members});"
                plan = json.loads(sql(prepare + 'EXPLAIN (ANALYZE,BUFFERS,COSTS OFF,TIMING OFF,FORMAT JSON) ' + execute, database))
                actual = json.loads(sql(prepare + execute, database))
                # Reference deliberately has no namespace SQL predicate. Parse
                # every inspected category and apply literal matching in Python.
                raw = sql(f"SELECT se.stream_version,se.category,"
                    f"(((hashtextextended(se.original_stream_id::text,0)%{members})+{members})%{members}) "
                    f"FROM kiroku.stream_events se WHERE stream_id=0 AND stream_version>{cursor} "
                    f"AND stream_version<={size} ORDER BY stream_version LIMIT 32;", database).splitlines()
                rows = [row.split('|') for row in raw]
                expected = {'scanned':len(rows),'last_scanned':int(rows[-1][0]) if rows else None,
                    'matches':[int(p) for p,c,m in rows if (c==namespace or c.startswith(namespace+':')) and int(m)==member]}
                assert actual == expected
                top = plan[0]['Plan']
                scanned = [n for n in nodes(top) if n.get('Relation Name') == 'stream_events']
                examined = sum((n.get('Actual Rows',0)+n.get('Rows Removed by Filter',0)) * n.get('Actual Loops',1) for n in scanned)
                buffers = top.get('Shared Hit Blocks',0)+top.get('Shared Read Blocks',0)
                evidence['cases'].append({'database':database,'event_positions':size,'mode':mode,
                    'variant':'namespace_bounded_global_window','cursor':cursor,'namespace':namespace,
                    'member':member,'members':members,'sql':prepare+execute,'plan':plan,
                    'result':actual,'expected_result':expected,'correct_results':True,
                    'rows_examined':examined,'buffers':buffers,
                    'streams_join':any(n.get('Relation Name')=='streams' for n in nodes(top)),
                    'within_budget':examined<=64 and buffers<=64})
                save()
