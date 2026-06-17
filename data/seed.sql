INSERT INTO participants (id, name, team, target) VALUES
    ('alice', 'Alice', 'Sharks', 300000),
    ('bob', 'Bob', 'Sharks', 300000),
    ('chloe', 'Chloe', 'Eagles', 300000),
    ('dave', 'Dave', 'Eagles', 300000),
    ('erin', 'Erin', 'Wolves', 300000),
    ('finn', 'Finn', 'Wolves', 300000)
ON CONFLICT (id) DO UPDATE 
    SET name = EXCLUDED.name, team = EXCLUDED.team, target = EXCLUDED.target;