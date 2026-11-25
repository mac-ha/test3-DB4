CREATE SCHEMA clinic_lab;

CREATE TABLE clinic_lab.patients (
    patient_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE clinic_lab.doctors (
    doctor_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE clinic_lab.appointments (
    appointment_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    patient_id INTEGER NOT NULL,
    doctor_id INTEGER NOT NULL,
    appointment_day DATE NOT NULL,
    slot_time TIME NOT NULL,

    status VARCHAR(20) NOT NULL
    CHECK (status IN ('BOOKED','ATTENDED','CANCELLED')),

    CONSTRAINT fk_patient
        FOREIGN KEY (patient_id)
        REFERENCES clinic_lab.patients(patient_id),

    CONSTRAINT fk_doctor
        FOREIGN KEY (doctor_id)
        REFERENCES clinic_lab.doctors(doctor_id)
);

CREATE TABLE clinic_lab.clinic_summary (
    summary_date DATE PRIMARY KEY,
    booked_count INTEGER NOT NULL,
    attended_count INTEGER NOT NULL,
    cancelled_count INTEGER NOT NULL
);

INSERT INTO clinic_lab.patients (full_name)
VALUES
('John Banda'),
('Mary Phiri'),
('Peter Tembo');

INSERT INTO clinic_lab.doctors (full_name)
VALUES
('Dr Mwale'),
('Dr Zulu'),
('Dr Chanda');

INSERT INTO clinic_lab.appointments
(patient_id, doctor_id, appointment_day, slot_time, status)
VALUES
(1,1,'2026-11-25','09:00','BOOKED'),
(2,1,'2026-11-25','10:00','BOOKED'),

(3,2,'2026-11-25','09:00','ATTENDED'),
(1,2,'2026-11-25','11:00','BOOKED'),

(2,3,'2026-11-25','09:00','CANCELLED'),
(3,3,'2026-11-25','10:00','BOOKED');

--B--
CREATE OR REPLACE FUNCTION
clinic_lab.fn_daily_load(
    p_doctor_id INTEGER,
    p_day DATE
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_count INTEGER;
BEGIN

    PERFORM 1
    FROM clinic_lab.doctors
    WHERE doctor_id = p_doctor_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doctor does not exist';
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM clinic_lab.appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN COALESCE(v_count,0);

END;
$$;

--C--
CREATE OR REPLACE PROCEDURE
clinic_lab.pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id INTEGER,
    p_day DATE,
    p_slot TIME
)
LANGUAGE plpgsql
AS $$
BEGIN

    IF NOT EXISTS (
        SELECT 1
        FROM clinic_lab.patients
        WHERE patient_id = p_patient_id
    ) THEN
        RAISE EXCEPTION 'Invalid patient';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM clinic_lab.doctors
        WHERE doctor_id = p_doctor_id
    ) THEN
        RAISE EXCEPTION 'Invalid doctor';
    END IF;

    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION
        'Past appointment dates not allowed';
    END IF;

    IF p_slot NOT IN
    (
        TIME '09:00',
        TIME '10:00',
        TIME '11:00',
        TIME '12:00'
    )
    THEN
        RAISE EXCEPTION
        'Unsupported appointment slot';
    END IF;

    INSERT INTO clinic_lab.appointments
    (
        patient_id,
        doctor_id,
        appointment_day,
        slot_time,
        status
    )
    VALUES
    (
        p_patient_id,
        p_doctor_id,
        p_day,
        p_slot,
        'BOOKED'
    );

END;
$$;

--D--

CREATE OR REPLACE FUNCTION
clinic_lab.fn_prevent_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN

    IF NEW.status <> 'CANCELLED' THEN

        IF EXISTS
        (
            SELECT 1
            FROM clinic_lab.appointments a
            WHERE a.doctor_id = NEW.doctor_id
            AND a.appointment_day =
                NEW.appointment_day
            AND a.slot_time =
                NEW.slot_time
            AND a.status <> 'CANCELLED'
            AND (
                TG_OP = 'INSERT'
                OR a.appointment_id <>
                   NEW.appointment_id
            )
        )
        THEN
            RAISE EXCEPTION
            'Appointment slot already taken';
        END IF;

    END IF;

    RETURN NEW;

END;
$$;

--trigger

CREATE TRIGGER trg_prevent_clash
BEFORE INSERT OR UPDATE
ON clinic_lab.appointments
FOR EACH ROW
EXECUTE FUNCTION
clinic_lab.fn_prevent_clash();

--E
CREATE OR REPLACE VIEW
clinic_lab.v_today_appointments AS
SELECT
    p.full_name AS patient_name,
    d.full_name AS doctor_name,
    a.slot_time
FROM clinic_lab.appointments a
JOIN clinic_lab.patients p
ON a.patient_id = p.patient_id
JOIN clinic_lab.doctors d
ON a.doctor_id = d.doctor_id
WHERE a.appointment_day = CURRENT_DATE
AND a.status = 'BOOKED';

--F--

CREATE INDEX idx_appointment_day_doctor
ON clinic_lab.appointments
(
    appointment_day,
    doctor_id
);

EXPLAIN

SELECT *
FROM clinic_lab.appointments
WHERE appointment_day = DATE '2026-11-25'
AND doctor_id = 1;

--G--

CREATE OR REPLACE PROCEDURE
clinic_lab.pr_refresh_clinic_summary(
    p_day DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_booked INTEGER;
    v_attended INTEGER;
    v_cancelled INTEGER;
BEGIN

    SELECT COUNT(*)
    INTO v_booked
    FROM clinic_lab.appointments
    WHERE appointment_day = p_day
    AND status = 'BOOKED';

    SELECT COUNT(*)
    INTO v_attended
    FROM clinic_lab.appointments
    WHERE appointment_day = p_day
    AND status = 'ATTENDED';

    SELECT COUNT(*)
    INTO v_cancelled
    FROM clinic_lab.appointments
    WHERE appointment_day = p_day
    AND status = 'CANCELLED';

    INSERT INTO clinic_lab.clinic_summary
    (
        summary_date,
        booked_count,
        attended_count,
        cancelled_count
    )
    VALUES
    (
        p_day,
        v_booked,
        v_attended,
        v_cancelled
    )

    ON CONFLICT (summary_date)
    DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;

END;
$$;
